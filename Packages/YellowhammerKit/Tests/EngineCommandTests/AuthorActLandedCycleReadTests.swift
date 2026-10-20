import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Synchronization
import Testing

// Issue #559 (spec: feature-authoring/select-the-next-feature, morning-report/triage-the-morning): once
// the in-flight Cycle has landed, no build Act reads the board for it again, so the author Act reads it
// before the merge closure, the settle gesture and selection decide from the Journal. Every reading board
// here reads through the writing board, so a write that overwrote the Operator's gesture before the read
// would be what the read sees.

/// Records the adoption candidates selection would be offered (``JournalStore/blockedCardsLeftByClosedFeatures()``)
/// at the moment the author Act calls it.
final class CandidateRecordingAuthoring: FeatureAuthoring, Sendable {
    private let state = Mutex<[String]?>(nil)

    /// Nil until selection is called.
    var candidates: [String]? { state.withLock { $0 } }

    func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        let candidates = try context.journal.blockedCardsLeftByClosedFeatures().map(\.issueID)
        state.withLock { $0 = candidates }
        return .noWorkAvailable
    }
}

@Suite("Author Act reads a landed Cycle before it settles or selects (#559)")
struct AuthorActLandedCycleReadTests {
    @Test("A Card cancelled on a landed Cycle is Shelved before the abandon, never carried forward or adopted")
    func cancelledCardIsShelvedBeforeTheAbandon() async throws {
        let world = try await makeSettleWorld(landed: true)
        try resolveWaitingCard(world)
        try await abandonOnTheBoard(world)
        let reading = FakeReadingBoard([page(objects: [object("BACK-2", state: stateCanceledByCategory)])])
        try await reading.readThrough(world.boards)
        let baseline = await world.boards.writing.writeLog.count
        let authoring = CandidateRecordingAuthoring()

        try await authorAct(world, reading: reading, authoring: authoring).run()

        #expect(await reading.calls.count == 1, "a landed in-flight Cycle is read even with nothing to bank")
        let events = try world.journal.events().map(\.type)
        let shelvedAt = try #require(events.firstIndex(of: .cardShelved))
        let releasedAt = try #require(events.firstIndex(of: .featureReleased))
        #expect(events.contains(.deltaReadCompleted))
        #expect(shelvedAt < releasedAt, "the Cancel is read before the settle gesture decides")
        #expect(try world.journal.card(id: world.blockedCardID).state == .shelved)
        #expect(try releasedCarriedForward(world).isEmpty)
        #expect(authoring.candidates == [])
        #expect(await world.boards.writing.writes(to: BoardObjectID(rawValue: "BACK-2"), since: baseline).isEmpty)
    }

    @Test("A Card trashed on a landed Cycle is set aside before the abandon and never adopted")
    func trashedCardIsSetAside() async throws {
        let world = try await makeSettleWorld(landed: true)
        try resolveWaitingCard(world)
        try await abandonOnTheBoard(world)
        let reading = FakeReadingBoard([page(objects: [object("BACK-2", state: stateBlocked, isTrashed: true)])])
        try await reading.readThrough(world.boards)
        let baseline = await world.boards.writing.writeLog.count
        let authoring = CandidateRecordingAuthoring()

        try await authorAct(world, reading: reading, authoring: authoring).run()

        let card = try world.journal.card(id: world.blockedCardID)
        #expect(card.removedFromBoard == .trashed)
        #expect(card.state == .blocked)
        #expect(try releasedCarriedForward(world).isEmpty)
        #expect(authoring.candidates == [])
        #expect(await world.boards.writing.writes(to: BoardObjectID(rawValue: "BACK-2"), since: baseline).isEmpty)
    }

    @Test("A re-ready on a landed Cycle is recorded, not applied: the Card stays Blocked and adoptable")
    func reReadyOnALandedCycleIsRecordedNotApplied() async throws {
        let world = try await makeSettleWorld(landed: true)
        try resolveWaitingCard(world)
        try await abandonOnTheBoard(world)
        let reading = FakeReadingBoard([page(objects: [object("BACK-2", state: stateTodo)])])
        try await reading.readThrough(world.boards)
        let authoring = CandidateRecordingAuthoring()

        try await authorAct(world, reading: reading, authoring: authoring).run()

        let card = try world.journal.card(id: world.blockedCardID)
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.reviewerRejection.rawValue)
        let restated = try world.journal.events(ofType: .cardRestated)
        #expect(restated.map(\.event) == [.cardRestated(
            cardID: world.blockedCardID, issueID: "BACK-2", journalState: .blocked, boardState: "Todo"
        )])
        #expect(try releasedCarriedForward(world) == ["BACK-2"])
        #expect(authoring.candidates == ["BACK-2"])
    }

    @Test("A degraded read on a landed Cycle closes, settles and selects nothing")
    func degradedReadSettlesAndSelectsNothing() async throws {
        let world = try await makeSettleWorld(landed: true)
        try resolveWaitingCard(world)
        try await abandonOnTheBoard(world)
        let reading = FakeReadingBoard([.failure(.rateLimited(retryAfter: nil, budget: nil))])
        try await reading.readThrough(world.boards)
        let authoring = CandidateRecordingAuthoring()

        try await authorAct(world, reading: reading, authoring: authoring).run()

        let events = try world.journal.events().map(\.type)
        #expect(events.contains(.rateBudgetExhausted))
        #expect(!events.contains(.deltaReadCompleted))
        #expect(!events.contains(.featureReleased))
        #expect(!events.contains(.featureCompleted))
        #expect(authoring.candidates == nil, "selection never runs on a degraded read")
        #expect(try world.journal.inFlightFeature()?.feature.id == world.featureID)
        #expect(try world.journal.card(id: world.blockedCardID).state == .blocked)
    }

    @Test("A merge closure on a landed Cycle never carries forward a Card the Operator cancelled")
    func mergeClosureDoesNotCarryForwardACancelledCard() async throws {
        let world = try await makeMergeWorld(mergedRepositories: ["backend", "mobile"])
        try world.journal.write { db in
            try db.execute(
                sql: "UPDATE card SET state = ?, waiting_reason = NULL WHERE id = ?",
                arguments: [CardState.done.rawValue, world.waitingCardID]
            )
        }
        let reading = FakeReadingBoard([page(objects: [object("BACK-2", state: stateCanceledByCategory)])])
        try await reading.readThrough(world.boards)
        let baseline = await world.boards.writing.writeLog.count
        let authoring = CandidateRecordingAuthoring()

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: mergeClosureObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(),
            board: ActBoard(reading: reading, writing: world.boards.writing, provisioning: world.boards.provisioning),
            repositories: mergeWorldRepositories(world),
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(closure: FeatureMergeClosure()), authoring: authoring,
                settle: FeatureSettleGesture()
            ).work
        )
        try await invocation.run()

        #expect(await reading.calls.count == 1)
        let closed = try world.journal.events(ofType: .featureClosedByMerge)
        guard case .featureClosedByMerge(_, _, _, let carried, _, _)? = closed.first?.event else {
            Issue.record("expected featureClosedByMerge")
            return
        }
        #expect(carried.isEmpty)
        #expect(try world.journal.card(id: world.blockedCardID).state == .shelved)
        #expect(authoring.candidates == [])
        #expect(await world.boards.writing.writes(to: BoardObjectID(rawValue: "BACK-2"), since: baseline).isEmpty)
    }

    @Test("The author Act reads the board even with no Feature in flight and nothing Waiting on You")
    func readsWithNothingInFlightAndNothingToBank() async throws {
        let world = try await makeSettleWorld(inFlight: false, landed: true)
        try resolveWaitingCard(world)
        let reading = FakeReadingBoard([page()])
        try await reading.readThrough(world.boards)
        let authoring = CandidateRecordingAuthoring()

        try await authorAct(world, reading: reading, authoring: authoring).run()

        #expect(await reading.calls.count == 1, "every Act reconciles the Board before it decides (P22.3)")
        #expect(authoring.candidates == ["BACK-2"])
    }

    @Test("While an unlanded Cycle is in flight the author Act reads, but the Cards stay the build Act's")
    func readsWhileAnUnlandedCycleIsInFlight() async throws {
        let world = try await makeSettleWorld(landed: false)
        await world.seedFeatureIssueState(FeatureDisposition.legacySettleStateNames[0])
        let authoring = CandidateRecordingAuthoring()

        try await authorAct(world, reading: world.reading, authoring: authoring).run()

        #expect(await world.reading.calls.count == 1)
        #expect(try world.journal.events(ofType: .deltaReadCompleted).count <= 1)
        #expect(try world.journal.events(ofType: .featureCompleted).isEmpty)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
    }
}

// MARK: - Helpers

/// An author Act over `world` with the real settle gesture. No predecessor gate: the world configures no
/// repositories for the ancestry walk, and the merge closure has its own test above.
private func authorAct(
    _ world: SettleWorld, reading: FakeReadingBoard, authoring: CandidateRecordingAuthoring
) -> EngineInvocation {
    EngineInvocation(
        act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
        trigger: .scheduled, runID: RunID(),
        board: ActBoard(reading: reading, writing: world.boards.writing, provisioning: world.boards.provisioning),
        workspace: world.workspace,
        work: AuthorAct(
            predecessorGate: nil, authoring: authoring, settle: FeatureSettleGesture()
        ).work
    )
}

/// Takes the world's Waiting on You Card out of Waiting on You, so nothing is left to bank and only the
/// landed in-flight Cycle can be the reason the author Act reads.
private func resolveWaitingCard(_ world: SettleWorld) throws {
    try world.journal.write { db in
        try db.execute(
            sql: "UPDATE card SET state = ?, waiting_reason = NULL WHERE id = ?",
            arguments: [CardState.done.rawValue, world.waitingCardID]
        )
    }
}

/// Moves the Feature Issue to *abandoned* on the writing board itself: a reading board linked through
/// ``FakeReadingBoard/readThrough(_:team:)`` answers the settle gesture's issue read from there, not from
/// a seeded issue.
private func abandonOnTheBoard(_ world: SettleWorld) async throws {
    let abandonedName = FeatureDisposition.legacySettleStateNames[1]
    await world.boards.provisioning.seed(state: abandonedName, team: teamID, category: .started)
    let states = try await world.boards.provisioning.workflowStates(team: teamID)
    let abandoned = try #require(states.first { $0.name == abandonedName })
    _ = try await world.boards.writing.updateIssue(
        BoardObjectID(rawValue: "FEAT-1"), BoardIssueChange(workflowState: abandoned.id)
    )
}

private func releasedCarriedForward(_ world: SettleWorld) throws -> [String] {
    let released = try world.journal.events(ofType: .featureReleased)
    guard case .featureReleased(_, _, let carriedForward, _, _, _)? = released.first?.event else {
        Issue.record("expected featureReleased")
        return []
    }
    return carriedForward
}
