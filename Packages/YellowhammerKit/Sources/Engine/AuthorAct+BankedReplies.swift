import Domain
import Journal

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
    static func run(context: ActContext, unansweredNightsMax: Int) async throws {
        guard let board = context.board else { return }
        let journal = context.journal
        if let (_, cycleID) = try journal.inFlightFeature(), try !journal.isCycleLanded(cycleID: cycleID) {
            return
        }
        guard try journal.hasWaitingOnYouCardInLandedCycle() else { return }

        let read = DeltaRead(
            journal: context.journal, board: board.reading, runID: context.runID, act: context.act,
            nightID: context.night.id, repositories: nil
        )
        switch try await read.perform() {
        case .read:
            try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: unansweredNightsMax)
        case .degraded:
            // Already recorded by the Delta Read itself; nothing further to do here.
            break
        }
    }
}
