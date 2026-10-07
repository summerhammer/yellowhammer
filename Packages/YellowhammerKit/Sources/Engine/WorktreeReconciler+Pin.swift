import Domain
import Journal
import Repositories

// The Feature Branch pin that precedes a ghost-Worktree purge (OQ123), split out of
// WorktreeReconciler+Ghost.swift to keep each file small.

/// What pinning a ghost Worktree's Feature Branch settled, before the purge may run.
enum GhostPin: Equatable {
    /// The branch tip is pinned and recorded in the Journal; the purge may run.
    case pinned(commit: String)
    /// The branch no longer exists, but the Journal's `last_known_good_commit` is still in the object
    /// store: it is pinned and recorded in the Journal, and the purge may run (OQ133 duty 1).
    case pinnedLastKnownGood(commit: String)
    /// The branch no longer exists and nothing else is recoverable, so there is nothing to pin; the purge
    /// may run. `lostCommit` is the Journal's `last_known_good_commit` whose object is gone too, nil when
    /// none was recorded (OQ133 duty 2).
    case nothingToPin(lostCommit: String?)
    /// The pin could not be written; the purge must NOT run. `reason` names the pin ref.
    case held(reason: String)
}

extension WorktreeReconciler {
    /// Pins `branch`'s tip at `refs/yellowhammer/recovery/<branch>` in the MAIN repository — the Worktree's
    /// directory is gone — after recording the SHA in the Journal, so the Journal record always leads the
    /// ref and a crash at any point leaves enough to resume from (OQ123).
    ///
    /// A recovery commit already in the Journal (a crash after recording it) is simply re-pinned:
    /// `update-ref` is idempotent, and that covers a crash between the Journal write and the ref write.
    /// Otherwise the branch's tip is resolved: a commit is recorded, then pinned; an absent branch has
    /// nothing to protect. That last case is a local reading, not a spec ruling: the branch is already gone
    /// (the Operator removed the Worktree in Orca ADE, which deleted directory and branch), and refusing
    /// would wedge the lane forever with no non-destructive remedy. It is not given up on first: the lane's
    /// `last_known_good_commit` (the tip of its accepted work) is pinned instead when that object is still
    /// in the repository — an unreachable commit usually is until `git gc` (OQ133). Anything else — no
    /// configured repository path, git failing, the ref write refused — holds the Worktree.
    func pinFeatureBranch(_ record: WorktreeRecord, branch: FeatureBranch) async throws -> GhostPin {
        let ref = FeatureBranchRecoveryPin.ref(for: branch)
        guard let configured = repositories?.repositoryPath(named: record.repository) else {
            return .held(reason: Self.heldReason(
                ref, record, detail: "no repository path is configured for \(record.repository)"
            ))
        }
        let repositoryPath = Self.expandedPath(configured)

        if let recorded = try journal.recoveryCommit(featureID: record.featureID, repository: record.repository) {
            return await writePin(recorded, branch: branch, record: record, repositoryPath: repositoryPath)
        }

        switch await recoveryPin.tip(of: branch, repositoryPath: repositoryPath) {
        case .commit(let commit):
            try journal.recordRecoveryCommit(
                featureID: record.featureID, repository: record.repository, commit: commit, runID: runID
            )
            return await writePin(commit, branch: branch, record: record, repositoryPath: repositoryPath)
        case .absent:
            return try await pinLastKnownGood(record, branch: branch, repositoryPath: repositoryPath)
        case .failed(let detail):
            return .held(reason: Self.heldReason(ref, record, detail: detail))
        }
    }

    /// OQ133 duty 1: with the Feature Branch gone, pins the lane's `last_known_good_commit` if the object is
    /// still there, so re-allocation recovers from it exactly as from a branch tip. The Journal record
    /// leads the ref here too.
    private func pinLastKnownGood(
        _ record: WorktreeRecord, branch: FeatureBranch, repositoryPath: String
    ) async throws -> GhostPin {
        guard let knownGood = record.lastKnownGoodCommit else {
            return .nothingToPin(lostCommit: nil)
        }
        switch await recoveryPin.commitExists(knownGood, repositoryPath: repositoryPath) {
        case .present:
            try journal.recordRecoveryCommit(
                featureID: record.featureID, repository: record.repository, commit: knownGood, runID: runID
            )
            switch await writePin(knownGood, branch: branch, record: record, repositoryPath: repositoryPath) {
            case .pinned(let commit):
                return .pinnedLastKnownGood(commit: commit)
            case let other:
                return other
            }
        case .absent:
            return .nothingToPin(lostCommit: knownGood)
        case .failed(let detail):
            return .held(reason: Self.heldReason(FeatureBranchRecoveryPin.ref(for: branch), record, detail: detail))
        }
    }

    private func writePin(
        _ commit: String, branch: FeatureBranch, record: WorktreeRecord, repositoryPath: String
    ) async -> GhostPin {
        guard await recoveryPin.pin(commit, branch: branch, repositoryPath: repositoryPath) else {
            return .held(reason: Self.heldReason(
                FeatureBranchRecoveryPin.ref(for: branch), record, detail: "git update-ref refused \(commit)"
            ))
        }
        return .pinned(commit: commit)
    }

    private static func heldReason(_ ref: String, _ record: WorktreeRecord, detail: String) -> String {
        "could not pin the Feature Branch at \(ref) in \(record.repository) (\(detail)); " +
            "the ghost Worktree \(record.worktreeID) was kept, not purged"
    }
}
