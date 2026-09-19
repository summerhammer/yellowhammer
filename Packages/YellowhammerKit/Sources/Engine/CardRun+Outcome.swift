import Domain
import Foundation
import Journal

extension CardRun {
    /// Tells the Journal how the run ended, revalidating the Lease before each write, and decides whether
    /// this Card run is over or a fresh Attempt should be dispatched (roadmap P8.7). Only a reviewer
    /// approval after a passing (or declared-none) Check ends the Attempt in success and moves the Card to
    /// Done; a question ends the run without consuming the Attempt budget; every other ending — hard
    /// failure, Crashed-Unknown, `rounds-exhausted` — retries while the Attempt budget has room, and Blocks
    /// the Card once it is spent.
    func conclude(_ end: CardRunEnd, frame: CardRunFrame) async throws -> CardRunAction {
        switch end {
        case .approved(let commit):
            try endAttempt(.success, frame: frame)
            // The Card's work is judged good, so a reset must never rewind it (object-guide: Worktree).
            try frame.revalidateLease()
            try frame.journal.recordWorktreeKnownGood(
                id: frame.worktree.id, commit: commit, runID: frame.context.act.runID
            )
            try await frame.transition(.done)
            return .stop

        case .ending(let ending):
            try endAttempt(ending, frame: frame)
            guard ending.consumesAttempt else {
                // A question would move the Card to Waiting on You, which needs the Operator's board
                // identity: it is wired nowhere yet (P11), so the Card returns to Ready like every other
                // unconsuming ending. Asking never retries: it consumes no Attempt to retry with.
                try await frame.transition(.ready)
                return .stop
            }
            // A hard failure or Crashed-Unknown: a fresh Attempt on a different Route while the Attempt
            // budget has room (P8.7); the Card stays In Progress between Attempts.
            guard let attempt = frame.attempt else { return .stop }
            return try await retryOrBlock(attempt: attempt, lastRoundLens: nil, frame: frame)

        case .roundsExhausted(let lens):
            // The Round that spent the round budget was already recorded, on either Lens's own loop. This
            // ends the Attempt `rounds-exhausted` — that Round's own comment already told the board why —
            // and then decides the Card's fate from the Attempt budget, not the round budget alone.
            guard let attempt = frame.attempt else { return .stop }
            let roundCount = try frame.journal.attemptHistory(cardID: frame.card.id).attempts
                .first { $0.id == attempt.id }?.rounds.count ?? 0
            try endAttempt(.roundsExhausted(rounds: roundCount), frame: frame)
            try frame.revalidateLease()
            try frame.record(.roundsExhausted, detail: lens.rawValue)
            return try await retryOrBlock(attempt: attempt, lastRoundLens: lens, frame: frame)
        }
    }

    /// Shared by every consuming ending: retries with a fresh Attempt while the Attempt budget has room,
    /// Blocks the Card once it is spent. `lastRoundLens` is the Lens of the Round that spent the round
    /// budget, when that is why the Attempt ended; nil for a hard failure or Crashed-Unknown, which block
    /// `hard failure`.
    private func retryOrBlock(
        attempt: AttemptRecord, lastRoundLens: Lens?, frame: CardRunFrame
    ) async throws -> CardRunAction {
        let budget = try attemptBudget(consumedInEpochOf: attempt, frame: frame)
        guard budget.isExhausted else {
            // The round budget alone never blocks a Card, and neither does a lone hard failure or
            // Crashed-Unknown while Attempts remain: this run dispatches a fresh Attempt on a different
            // Route rather than returning the Card to Ready.
            return .retry
        }
        try frame.revalidateLease()
        try await frame.transition(.blocked(Self.blockReason(
            lastEndingOutcome: lastRoundLens == nil ? nil : AttemptOutcome.roundsExhausted.rawValue,
            lastRoundLens: lastRoundLens
        )))
        let account = try consumptionDescription(epoch: attempt.budgetEpoch, frame: frame)
        try frame.record(.attemptsExhausted, detail: account)
        return .stop
    }

    /// The Attempt budget for the epoch `endedAttempt` just ended: `consumed` counts every ended Attempt
    /// of that epoch whose ending consumed one, `endedAttempt` itself included — a `question` never
    /// counts, and it is the only ending that does not. Reads the single source of consumption counting,
    /// ``AttemptHistory/consumption(inEpoch:)``.
    private func attemptBudget(
        consumedInEpochOf endedAttempt: AttemptRecord, frame: CardRunFrame
    ) throws -> AttemptBudget {
        let history = try frame.journal.attemptHistory(cardID: frame.card.id)
        let consumed = history.consumption(inEpoch: endedAttempt.budgetEpoch).consumed
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
