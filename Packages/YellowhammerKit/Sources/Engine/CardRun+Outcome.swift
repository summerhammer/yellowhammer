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

        case .roundsExhausted(let lens):
            // The Round that spent the budget was already recorded, on either Lens's own loop. This ends
            // the Attempt `rounds-exhausted` — that Round's own comment already told the board why — and
            // then decides the Card's fate from the Attempt budget, not the round budget alone.
            guard let attempt = frame.attempt else { return }
            let roundCount = try frame.journal.attemptHistory(cardID: frame.card.id).attempts
                .first { $0.id == attempt.id }?.rounds.count ?? 0
            try endAttempt(.roundsExhausted(rounds: roundCount), frame: frame)
            try frame.revalidateLease()
            try frame.record(.roundsExhausted, detail: lens.rawValue)

            let budget = try attemptBudget(consumedInEpochOf: attempt, frame: frame)
            if budget.isExhausted {
                // Both budgets spent: the Card blocks, told which Lens's Round was the run's last.
                try await frame.transition(.blocked(lens == .check ? .blockedByCheck : .blockedByReviewer))
            } else {
                // The round budget alone never blocks a Card. A fresh Attempt on a different Route is
                // roadmap P8.7: this run does not re-dispatch, and the Card waits back in Ready for one.
                try await frame.transition(.ready)
            }
        }
    }

    /// The Attempt budget for the epoch `endedAttempt` just ended: `consumed` counts every ended Attempt
    /// of that epoch whose ending consumed one, `endedAttempt` itself included — a `question` never
    /// counts, and it is the only ending that does not.
    private func attemptBudget(
        consumedInEpochOf endedAttempt: AttemptRecord, frame: CardRunFrame
    ) throws -> AttemptBudget {
        let history = try frame.journal.attemptHistory(cardID: frame.card.id)
        let consumed = history.attempts.filter {
            $0.budgetEpoch == endedAttempt.budgetEpoch && $0.result != nil
                && $0.result != AttemptOutcome.question.rawValue
        }.count
        return AttemptBudget(max: attemptsPerCard, consumed: consumed)
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
