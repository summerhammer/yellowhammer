import Domain
import Journal
import Repositories

// The WIP-commit and reset half of reconciliation, split out of WorktreeReconciler.swift to keep it
// under the file length limit.

extension WorktreeReconciler {
    /// Commits any uncommitted edits in `record`'s Worktree as a WIP commit on the Feature Branch and
    /// resets to the last known-good commit, or confirms a clean tree is already caught up. Never runs
    /// on a path that is not quiescent: `reconcile(feature:)` fences it first.
    func reconcileCommitState(
        _ record: WorktreeRecord, branch: FeatureBranch
    ) async throws -> WorktreeReconciliationOutcome {
        switch await committer.commitWIP(
            worktreePath: record.path, branch: branch, repository: record.repository
        ) {
        case .committed(let commit, let wipRef):
            return try await afterWIPCommit(record, branch: branch, commit: commit, wipRef: wipRef)
        case .noChanges(let headCommit, _, let wipCommit):
            return try await confirmClean(record, branch: branch, headCommit: headCommit, wipCommit: wipCommit)
        case .refused(let reason), .failed(let reason):
            try recordFailure(record, reason: reason)
            return .failed(record, reason: reason)
        }
    }

    /// A WIP commit was just written. Records it, then — when a known-good commit is recorded — resets
    /// the Worktree to it. The WIP commit is recorded and stands even if the reset then refuses or
    /// fails: reconciliation never loses a commit it already made.
    private func afterWIPCommit(
        _ record: WorktreeRecord, branch: FeatureBranch, commit: String, wipRef: String
    ) async throws -> WorktreeReconciliationOutcome {
        let recorded = try journal.recordWorktreeWIP(id: record.id, commit: commit, runID: runID)

        var resetTo: String?
        if let knownGood = record.lastKnownGoodCommit {
            switch await committer.resetToKnownGood(worktreePath: record.path, branch: branch, knownGood: knownGood) {
            case .reset(let to, _):
                resetTo = to
            case .refused(let reason), .failed(let reason):
                try recordFailure(record, reason: reason)
                return .failed(recorded, reason: reason)
            }
        }

        try journal.append(
            .worktreeWIPCommitted(
                featureID: record.featureID, repository: record.repository,
                wipCommit: commit, wipRef: wipRef, resetTo: resetTo
            ),
            act: act, runID: runID, nightID: nightID
        )
        return .wipCommitted(recorded, wipCommit: commit, wipRef: wipRef, resetTo: resetTo)
    }

    /// The tree is clean. Covers a crash between a WIP commit and recording it (recorded here,
    /// idempotently) and a crash between committing and resetting (reset here). A repeat reconcile of
    /// an already-settled Worktree does neither and reports `.clean` with no event appended.
    private func confirmClean(
        _ record: WorktreeRecord, branch: FeatureBranch, headCommit: String, wipCommit: String?
    ) async throws -> WorktreeReconciliationOutcome {
        var current = record
        if let wipCommit, current.wipCommit == nil {
            current = try journal.recordWorktreeWIP(id: record.id, commit: wipCommit, runID: runID)
        }

        if let knownGood = current.lastKnownGoodCommit, headCommit != knownGood {
            switch await committer.resetToKnownGood(worktreePath: record.path, branch: branch, knownGood: knownGood) {
            case .reset:
                break
            case .refused(let reason), .failed(let reason):
                try recordFailure(record, reason: reason)
                return .failed(current, reason: reason)
            }
        }

        return .clean(current)
    }

    func recordFailure(_ record: WorktreeRecord, reason: String) throws {
        try journal.append(
            .worktreeReconciliationFailed(
                featureID: record.featureID, repository: record.repository, path: record.path, reason: reason
            ),
            act: act, runID: runID, nightID: nightID
        )
    }
}
