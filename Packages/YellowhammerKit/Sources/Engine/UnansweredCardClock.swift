import Domain
import Journal

/// The Card side of the unanswered-Nights bound (roadmap P11.4; spec: bounds/bound-unanswered-nights):
/// advances the clock for every Waiting on You Card in the named Cycles, then auto-Blocks every Card the
/// advance (or an earlier Act's advance, if this Act crashed between counting and blocking) left past
/// the bound. Never releases or touches a Worktree — this bound's firing releases nothing but the Card's
/// own board state, and a Worktree's exit is landing.
enum UnansweredCardClock {
    static func run(cycleIDs: [Int64], unansweredNightsMax: Int, context: ActContext) async throws {
        guard !cycleIDs.isEmpty else { return }
        _ = try context.journal.advanceCardUnansweredClocks(
            cycleIDs: cycleIDs, nightID: context.night.id, unansweredNightsMax: unansweredNightsMax,
            act: context.act, runID: context.runID
        )
        let overdue = try context.journal.cardsPastUnansweredBound(
            cycleIDs: cycleIDs, unansweredNightsMax: unansweredNightsMax
        )
        try await CardAutoBlock.specific(
            cards: overdue,
            reason: { card in card.waitingReason == .divergence ? .decisionOverdue : .replyOverdue },
            context: context
        )
    }
}
