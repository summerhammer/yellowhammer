import Domain
import Journal

/// What ``PostLandingReplies/run(context:unansweredNightsMax:)`` did, so the author Act's own
/// unanswered-Nights clock advance (right after this step, roadmap P11.4) knows whether it is safe to
/// spend: a degraded read must never be charged as silence, since an unread answer is not silence.
enum PostLandingRepliesOutcome: Equatable, Sendable {
    /// No Board is bound: nothing was read, and the clock advances anyway (a Journal-only Project still
    /// spends its own Nights).
    case noBoard
    /// A Delta Read ran and completed; replies (if any) were applied.
    case read
    /// A Delta Read ran but degraded; the clock must not advance this Act.
    case degraded
    /// Nothing to do (an unlanded in-flight Cycle owns its own Cards, or no Card is Waiting on You in a
    /// landed Cycle) — safe for the clock to advance, since nothing here was skipped for being unreadable.
    case skipped
}

/// Reads and banks replies to Cards left Waiting on You after their Feature has landed (roadmap P11.3;
/// spec: board-projection/read-board-changes-by-delta, OQ37). No build Act fires once a Cycle has
/// landed (``ActTriggerPredicate``), so nothing else ever reads the board for these Cards again — the
/// author Act runs this step itself, right after ``UnansweredPositionClock`` and strictly before the
/// predecessor gate (whose merge closure auto-Blocks a Waiting on You Card, and a reply must be banked
/// before that happens).
enum PostLandingReplies {
    /// Performs its own Delta Read and banking pass only when all of: a Board is bound, no unlanded
    /// Cycle is in flight (so this can never consume a Delta Read the build Act still needs), and at
    /// least one Card is Waiting on You in an already-landed Cycle (so a Project with nothing to bank
    /// spends no request).
    @discardableResult
    static func run(context: ActContext, unansweredNightsMax: Int) async throws -> PostLandingRepliesOutcome {
        guard let board = context.board else { return .noBoard }
        let journal = context.journal
        if let (_, cycleID) = try journal.inFlightFeature(), try !journal.isCycleLanded(cycleID: cycleID) {
            return .skipped
        }
        guard try journal.hasWaitingOnYouCardInLandedCycle() else { return .skipped }

        let read = DeltaRead(
            journal: context.journal, board: board.reading, runID: context.runID, act: context.act,
            nightID: context.night.id, repositories: nil
        )
        switch try await read.perform() {
        case .read:
            try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: unansweredNightsMax)
            return .read
        case .degraded:
            // Already recorded by the Delta Read itself; nothing further to do here.
            return .degraded
        }
    }
}
