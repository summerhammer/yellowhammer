import Domain
import Foundation

// A new Attempt starts fresh, never as a rescue (Attempt, Block and Reset Ruling 2026-09-19, OQ60):
// before a fresh Attempt or a Block, the prior Attempt's own commits plus any WIP commit are
// preserved under a stable per-Attempt ref, and only then is the Worktree reset to the last
// known-good commit. Split out of WorktreeCommitter.swift to keep it under the file length limit.

/// The outcome of preserving an Attempt's work and resetting the Worktree to a known-good commit.
public enum AttemptPreservationOutcome: Equatable, Sendable {
    /// The Feature Branch now points at `resetTo`. `preservedRef` and `preservedCommit` are nil when
    /// the tip already equalled `resetTo`: there was nothing to preserve.
    case reset(preservedRef: String?, preservedCommit: String?, resetTo: String)
    /// Refused: nothing was destroyed. Covers a missing or dirty-off-branch Worktree and an
    /// unresolvable known-good commit.
    case refused(reason: String)
    /// A git invocation failed unexpectedly.
    case failed(reason: String)
}

extension WorktreeCommitter {
    /// The ref an Attempt's preserved work is stable at: `refs/yellowhammer/attempts/<branch>/<id>`.
    public static func preservationRef(branch: FeatureBranch, attemptID: Int64) -> String {
        "refs/yellowhammer/attempts/\(branch.name)/\(attemptID)"
    }

    /// WIP-commits any uncommitted work, and — when the resulting Feature Branch tip differs from
    /// `knownGood` — preserves it under `attemptID`'s ref before resetting the Worktree and the
    /// Feature Branch tip to `knownGood`. `attemptID` nil when no Attempt is on record to attribute
    /// the work to: the WIP commit and reset still run, but nothing is preserved under a per-Attempt
    /// ref (the caller's Journal write, if any, is its own to skip).
    ///
    /// Idempotent: a Worktree already at `knownGood` with a clean tree writes no commit, creates no
    /// ref, and the reset is a no-op.
    public func preserveAndReset(
        worktreePath: String,
        branch: FeatureBranch,
        repository: String,
        attemptID: Int64?,
        knownGood: String
    ) async -> AttemptPreservationOutcome {
        switch await commitWIP(worktreePath: worktreePath, branch: branch, repository: repository) {
        case .committed(let commit, _):
            return await preserveTip(
                commit, worktreePath: worktreePath, branch: branch, attemptID: attemptID, knownGood: knownGood
            )
        case .noChanges(let headCommit, _, _):
            return await preserveTip(
                headCommit, worktreePath: worktreePath, branch: branch, attemptID: attemptID, knownGood: knownGood
            )
        case .refused(let reason):
            return .refused(reason: reason)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }

    private func preserveTip(
        _ tip: String, worktreePath: String, branch: FeatureBranch, attemptID: Int64?, knownGood: String
    ) async -> AttemptPreservationOutcome {
        guard tip != knownGood else {
            return await performReset(
                worktreePath: worktreePath, branch: branch, knownGood: knownGood,
                preservedRef: nil, preservedCommit: nil
            )
        }

        // With no Attempt to record the work against, the standing WIP ref holds the tip instead, as
        // reconciliation's does: commits ahead of known-good are never left to the reflog alone.
        let path = (worktreePath as NSString).expandingTildeInPath
        let refName = attemptID.map { Self.preservationRef(branch: branch, attemptID: $0) }
        let updateRef = await git.run([
            "-C", path, "update-ref", refName ?? "refs/yellowhammer/wip/\(branch.name)", tip
        ])
        guard updateRef.isSuccess else {
            return .failed(reason: "git update-ref exited \(updateRef.exitCode): \(updateRef.stderr)")
        }

        return await performReset(
            worktreePath: worktreePath, branch: branch, knownGood: knownGood,
            preservedRef: refName, preservedCommit: refName != nil ? tip : nil
        )
    }

    private func performReset(
        worktreePath: String, branch: FeatureBranch, knownGood: String,
        preservedRef: String?, preservedCommit: String?
    ) async -> AttemptPreservationOutcome {
        switch await resetToKnownGood(worktreePath: worktreePath, branch: branch, knownGood: knownGood) {
        case .reset(let to, _):
            return .reset(preservedRef: preservedRef, preservedCommit: preservedCommit, resetTo: to)
        case .refused(let reason):
            return .refused(reason: reason)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }
}
