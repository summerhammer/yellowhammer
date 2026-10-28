import Domain
import Journal

/// What ``PostLandingReplies/run(context:unansweredNightsMax:)`` did, so the author Act's own
/// unanswered-Nights clock advance (right after this step, roadmap P11.4) knows whether it is safe to
/// spend: a degraded read must never be charged as silence, since an unread answer is not silence. A
/// degraded read also stops the author Act from closing, settling or selecting on Card states it could not
/// read (issue #559; board-projection/read-board-changes-by-delta, `sync-boundary`).
enum PostLandingRepliesOutcome: Equatable, Sendable {
    /// No Board is bound: nothing was read, and the clock advances anyway (a Journal-only Project still
    /// spends its own Nights).
    case noBoard
    /// A Delta Read ran and completed; replies (if any) were applied.
    case read
    /// A Delta Read ran but did not complete (rate budget or request cap); the clock must not advance this
    /// Act, and nothing that depends on the board is decided.
    case degraded
}

/// The author Act's Board reconciliation (roadmap P11.3, P22.3; spec: board-projection/read-board-changes-by-delta,
/// OQ37): a Delta Read on every author Act, before anything that depends on the board. It banks replies to
/// Cards left Waiting on You after their Cycle landed — no build Act fires once a Cycle has landed
/// (``ActTriggerPredicate``), so nothing else ever reads the board for these Cards again — and the Refusal
/// clock, the unanswered-Nights clock, the predecessor gate (whose merge closure auto-Blocks a Waiting on You
/// Card, and a reply must be banked before that happens), the settle gesture and selection all decide
/// afterwards, on a board that was read.
///
/// The same read lets the Operator's gestures on a landed Cycle's Cards take effect before the merge
/// closure, the settle gesture and selection decide from the Journal (issue #559; spec:
/// feature-authoring/select-the-next-feature, morning-report/triage-the-morning): a Card cancelled in
/// Linear is Shelved, so it is never carried forward or adopted, and a trashed or archived one is set
/// aside. A Blocked → Todo re-ready is not applied here (``DeltaRead/acceptsReReady``): the author Act
/// never runs a Card, so the Card stays as the Journal has it (and, on a landed Cycle, adoptable); the read
/// records it as restated, and leaves the observation pending for the next build Act, which owns it
/// (``DeltaRead/ownsBuildDecisions``).
enum PostLandingReplies {
    /// Reads the board whenever one is bound. Replies are applied here only when no unlanded Cycle is in
    /// flight, or the in-flight one has landed: a reply to a Card of a Cycle the build Act is still running
    /// stays recorded, and that build Act resumes the Card (this Act would have to claim its Lease).
    @discardableResult
    static func run(context: ActContext, unansweredNightsMax: Int) async throws -> PostLandingRepliesOutcome {
        guard let board = context.board else { return .noBoard }
        let journal = context.journal

        var read = DeltaRead(
            journal: context.journal, board: board.reading, runID: context.runID, act: context.act,
            nightID: context.night.id, repositories: nil, installation: board.installation
        )
        read.acceptsReReady = false
        switch try await read.perform() {
        case .read:
            if let (_, cycleID) = try journal.inFlightFeature(),
               try !journal.isCycleLanded(cycleID: cycleID) && !journal.hasCycleHandoffBegun(cycleID: cycleID) {
                return .read
            }
            try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: unansweredNightsMax)
            return .read
        case .degraded:
            // Already recorded by the Delta Read itself; nothing further to do here.
            return .degraded
        }
    }
}
