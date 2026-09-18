import Domain
import Foundation
import Journal

extension CardRun {
    /// Tells the Journal how the run ended, revalidating the Lease before each write. Only a reviewer
    /// approval after a passing (or declared-none) Check ends the Attempt in success and moves the Card to
    /// Done; every other ending is recorded faithfully and minimally — the policies around them are later
    /// roadmap items, named where each is left.
    func conclude(_ end: CardRunEnd, frame: CardRunFrame) async throws {
        switch end {
        case .approved(let commit):
            try endAttempt(.success, frame: frame)
            // The Card's work is judged good, so a reset must never rewind it (object-guide: Worktree).
            try frame.revalidateLease()
            try frame.journal.recordWorktreeKnownGood(
                id: frame.worktree.id, commit: commit, runID: frame.context.act.runID
            )
            try await frame.transition(.done)

        case .ending(let ending):
            try endAttempt(ending, frame: frame)
            // No retry inside this Act and no Attempt budget here (P8.7). A question would move the Card to
            // Waiting on You, which needs the Operator's board identity: it is wired nowhere yet (P11), so
            // the Card returns to Ready like every other ending.
            try await frame.transition(.ready)

        case .round(let request):
            // The Round is recorded and the Attempt left open, the Card In Progress, its Lease released: the
            // state a killed run leaves, which a later Act can pick up. Re-dispatching the worker with the
            // feedback is the Round loop (P8.5 for the Check, P8.6 for the review), not this item. Ending the
            // Attempt here instead would misname a Round as an Attempt's end.
            try frame.revalidateLease()
            guard let attempt = frame.attempt else { return }
            try frame.journal.recordRound(
                attemptID: attempt.id, lens: request.lens, verdict: request.verdict,
                requestedChanges: request.requestedChanges, judgedCommit: request.judgedCommit,
                runID: frame.context.act.runID
            )
        }
    }

    private func endAttempt(_ ending: AttemptEnding, frame: CardRunFrame) throws {
        guard let attempt = frame.attempt else { return }
        try frame.revalidateLease()
        try frame.journal.endAttempt(
            attemptID: attempt.id, ending: ending, runID: frame.context.act.runID, act: frame.context.act.act,
            nightID: frame.context.act.night.id
        )
    }
}
