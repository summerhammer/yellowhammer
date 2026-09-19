import Domain
import Foundation
import Journal

/// What the fence → WIP-commit → preserve → reset sequence (Attempt, Block and Reset Ruling
/// 2026-09-19, OQ60) decided for the caller: whether a new Attempt may be dispatched.
enum CardRunResetResult: Sendable {
    /// The Worktree is at known-good. `wip` is what the new Attempt should carry as context, nil
    /// when there was nothing to preserve.
    case success(wip: WIPContext?)
    /// Refused or failed: nothing was destroyed, and nothing here is dispatched over it.
    case failure
}

extension CardRun {
    /// A new Attempt starts fresh, never as a rescue (OQ60): before dispatching one, the prior
    /// Attempt's own commits plus any WIP commit are preserved under a git ref recorded against it,
    /// and the Worktree and the Feature Branch tip reset to the last known-good commit. Re-reads the
    /// WorktreeRecord fresh, so an earlier Card reaching Done in this run's own advance of
    /// `last_known_good_commit` is never missed.
    func attemptReset(priorAttemptID: Int64?, frame: CardRunFrame) async throws -> CardRunResetResult {
        try frame.revalidateLease()
        guard let worktree = try frame.journal.heldWorktree(
            featureID: frame.context.feature.id, repository: frame.card.repository
        ) else {
            throw CardRunError.worktreeMissing(featureID: frame.context.feature.id, repository: frame.card.repository)
        }

        let outcome = await resetting.reset(
            worktreePath: worktree.path, branch: frame.branch, attemptID: priorAttemptID,
            knownGood: worktree.lastKnownGoodCommit
        )
        switch outcome {
        case .reset(let preserved):
            guard let preserved, let priorAttemptID else {
                try frame.record(.attemptReset, detail: "nothing to preserve")
                return .success(wip: nil)
            }
            try frame.revalidateLease()
            try frame.journal.recordAttemptPreservation(
                attemptID: priorAttemptID, ref: preserved.ref, commit: preserved.commit,
                resetTo: worktree.lastKnownGoodCommit ?? preserved.commit,
                runID: frame.context.act.runID, act: frame.context.act.act, nightID: frame.context.act.night.id
            )
            try frame.record(.attemptReset, detail: preserved.ref)
            return .success(wip: WIPContext(commit: preserved.commit, note: "preserved at \(preserved.ref)"))

        case .refused(let reason), .failed(let reason):
            try frame.record(.attemptResetFailed, detail: reason)
            return .failure
        }
    }

    /// The reset sequence run on a Block path (OQ60), against the Card's last Attempt in history —
    /// this run's own if it recorded one, or an earlier run's or Night's otherwise — or with no
    /// Attempt to attribute preserved work to at all when the Card never dispatched one. The Card
    /// stays Blocked whether this succeeds or fails: a failed reset never un-blocks a Card, it only
    /// means nothing here was destroyed either.
    @discardableResult
    func attemptResetBeforeBlock(card: CardRecord, frame: CardRunFrame) async throws -> CardRunResetResult {
        let history = try frame.journal.attemptHistory(cardID: card.id)
        return try await attemptReset(priorAttemptID: history.attempts.last?.id, frame: frame)
    }
}
