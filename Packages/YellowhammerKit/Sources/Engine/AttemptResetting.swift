import Domain
import Repositories

/// What one Attempt's work is preserved under, before a reset moved the Feature Branch tip away
/// from it (Attempt, Block and Reset Ruling 2026-09-19, OQ60).
public struct PreservedAttemptWork: Equatable, Sendable {
    public let ref: String
    public let commit: String

    public init(ref: String, commit: String) {
        self.ref = ref
        self.commit = commit
    }
}

/// The outcome of the fence → WIP-commit → preserve → reset sequence.
public enum AttemptResetOutcome: Equatable, Sendable {
    /// The Worktree and the Feature Branch tip are at the last known-good commit. `preserved` is nil
    /// when the tip already equalled it: there was nothing to preserve.
    case reset(preserved: PreservedAttemptWork?)
    /// Refused: nothing was destroyed. Covers a Worktree that is not quiescent, missing, dirty off
    /// the Feature Branch, or no known-good commit recorded to reset to.
    case refused(reason: String)
    /// A git invocation failed unexpectedly.
    case failed(reason: String)
}

/// The seam ``CardRun`` calls before every new Attempt of a Card that already ran one in this run,
/// on every Block path, and when a worker's question puts its Card in Waiting on You mid-run (Attempt,
/// Block and Reset Ruling 2026-09-19, OQ60; Landing Edge Cases Ruling 2026-10-01, OQ106): a new Attempt starts
/// fresh, never as a rescue. Pure git and filesystem work, mirroring ``RepositoryCheckRunning``'s
/// seam over ``WorktreeCheck``: Journal writes and Lease revalidation stay in ``CardRun``.
public protocol AttemptResetting: Sendable {
    /// `attemptID` is the prior Attempt's own, so the preservation ref names it; nil when the Card
    /// run has no Attempt to attribute preserved work to (a Block found with none dispatched at all).
    /// `knownGood` nil refuses outright: a reset with nowhere ruled-good to land is never attempted.
    func reset(
        worktreePath: String, branch: FeatureBranch, repository: String, attemptID: Int64?, knownGood: String?
    ) async -> AttemptResetOutcome
}

/// The real ``AttemptResetting``: fences the Worktree quiescent (the same rule reconciliation
/// applies), then WIP-commits, preserves and resets through ``WorktreeCommitter``.
public struct AttemptWorktreeReset: AttemptResetting {
    public let fencer: ProcessFencer
    public let committer: WorktreeCommitter

    public init(fencer: ProcessFencer = ProcessFencer(), committer: WorktreeCommitter = WorktreeCommitter()) {
        self.fencer = fencer
        self.committer = committer
    }

    public func reset(
        worktreePath: String, branch: FeatureBranch, repository: String, attemptID: Int64?, knownGood: String?
    ) async -> AttemptResetOutcome {
        guard let knownGood else {
            return .refused(reason: "no known-good commit recorded for this Worktree")
        }
        switch await fencer.fence(worktreePath: worktreePath) {
        case .quiescent:
            break
        case .notQuiescent(_, let remaining):
            return .refused(reason: "Worktree not quiescent: \(remaining.count) process(es) remaining")
        case .pathMissing(let path):
            return .refused(reason: "Worktree path does not exist: \(path)")
        }

        switch await committer.preserveAndReset(
            worktreePath: worktreePath, branch: branch, repository: repository, attemptID: attemptID,
            knownGood: knownGood
        ) {
        case .reset(let ref, let commit, _):
            if let ref, let commit {
                return .reset(preserved: PreservedAttemptWork(ref: ref, commit: commit))
            }
            return .reset(preserved: nil)
        case .refused(let reason):
            return .refused(reason: reason)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}
