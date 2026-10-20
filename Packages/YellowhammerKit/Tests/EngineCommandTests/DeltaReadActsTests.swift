import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Repositories
import Synchronization
import Testing

// board-projection/read-board-changes-by-delta, `sync-boundary` (roadmap P22.3): every Act reconciles the
// Board before a decision that depends on it or a write is replayed; a read that did not complete defers
// those decisions; and no Act consumes an observation another Act owns.

/// Notes how many Delta Reads the board had served when selection was asked to author.
private final class ReadCountingAuthoring: FeatureAuthoring, Sendable {
    private let reading: FakeReadingBoard
    private let state = Mutex<Int?>(nil)

    init(reading: FakeReadingBoard) {
        self.reading = reading
    }

    /// Nil until selection is called.
    var readsBeforeSelection: Int? { state.withLock { $0 } }

    func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        let reads = await reading.calls.count
        state.withLock { $0 = reads }
        return .noWorkAvailable
    }
}

private func authorInvocation(
    _ world: SettleWorld, reading: FakeReadingBoard, authoring: any FeatureAuthoring
) -> EngineInvocation {
    EngineInvocation(
        act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
        trigger: .scheduled, runID: RunID(),
        board: ActBoard(reading: reading, writing: world.boards.writing, provisioning: world.boards.provisioning),
        workspace: world.workspace,
        work: AuthorAct(predecessorGate: nil, authoring: authoring, settle: FeatureSettleGesture()).work
    )
}

@Suite("Every Act reconciles the Board first (P22.3)")
struct DeltaReadActsTests {
    // MARK: - Author

    @Test("The author Act has read the Board before selection decides")
    func authorReadsBeforeSelection() async throws {
        let world = try await makeSettleWorld(inFlight: false, landed: true)
        let reading = FakeReadingBoard([page()])
        try await reading.readThrough(world.boards)
        let authoring = ReadCountingAuthoring(reading: reading)

        try await authorInvocation(world, reading: reading, authoring: authoring).run()

        #expect(authoring.readsBeforeSelection == 1)
    }

    @Test("A refused read advances no clock and decides no settlement or selection")
    func refusedReadDefersClocksSettlementAndSelection() async throws {
        let world = try await makeSettleWorld(landed: true)
        let waitingBefore = try world.journal.card(id: world.waitingCardID).unansweredNights
        let reading = FakeReadingBoard([.failure(.rateLimited(retryAfter: nil, budget: nil))])
        try await reading.readThrough(world.boards)
        let authoring = ReadCountingAuthoring(reading: reading)

        try await authorInvocation(world, reading: reading, authoring: authoring).run()

        #expect(authoring.readsBeforeSelection == nil, "selection is deferred")
        #expect(try world.journal.card(id: world.waitingCardID).unansweredNights == waitingBefore)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        #expect(try world.journal.events(ofType: .refusalRepeated).isEmpty)
        #expect(try world.journal.inFlightFeature() != nil)

        // The control: the same world with a completed read does spend the clock, so the check above is not vacuous.
        let control = try await makeSettleWorld(landed: true)
        let controlReading = FakeReadingBoard([page()])
        try await controlReading.readThrough(control.boards)
        try await authorInvocation(
            control, reading: controlReading, authoring: ReadCountingAuthoring(reading: controlReading)
        ).run()
        #expect(try control.journal.card(id: control.waitingCardID).unansweredNights > waitingBefore)
    }

    @Test("An incomplete read — the request cap reached — defers the same decisions and records why")
    func incompleteReadDefersDependentDecisions() async throws {
        let world = try await makeSettleWorld(landed: true)
        let waitingBefore = try world.journal.card(id: world.waitingCardID).unansweredNights
        // Every page claims another: the read gives up at its request cap, with the Operator's Cancel unread.
        let endless = (0..<60).map { index in
            page(
                objects: [object("BACK-2", state: stateCanceledByCategory, updatedAt: TimeInterval(index))],
                nextObjectCursor: BoardCursor(rawValue: "o-\(index + 1)")
            )
        }
        let reading = FakeReadingBoard(endless)
        let authoring = ReadCountingAuthoring(reading: reading)

        try await authorInvocation(world, reading: reading, authoring: authoring).run()

        #expect(await reading.calls.count == 40)
        #expect(authoring.readsBeforeSelection == nil)
        #expect(try world.journal.events(ofType: .deltaReadIncomplete).count == 1)
        #expect(try world.journal.events(ofType: .deltaReadCompleted).isEmpty)
        #expect(try world.journal.boardSyncPoint() == nil, "no cursor moved past data it did not see")
        #expect(try world.journal.card(id: world.blockedCardID).state == .blocked, "the unread Cancel is not applied")
        #expect(try world.journal.card(id: world.waitingCardID).unansweredNights == waitingBefore)
    }

    // MARK: - Land

    @Test("The land Act reads the Board before it replays a deferred write, and replays it once it has")
    func landReadsBeforeItReplaysWrites() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await deferredWriteWorld(journal: journal, reading: FakeReadingBoard([page()]))
        let (boards, staleCardID, reading) = (world.boards, world.staleCardID, world.reading)
        try await world.invocation.run()

        let types = try journal.events().map(\.type)
        let readAt = try #require(types.firstIndex(of: .deltaReadCompleted))
        let replayedAt = try #require(types.firstIndex(of: .boardStateReposted))
        #expect(readAt < replayedAt)
        #expect(await reading.calls.count == 1)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "STALE-1")))
        #expect(issue.workflowState == scope.states[.inProgress])
        #expect(try journal.card(id: staleCardID).boardStateVersion == 1)
    }

    @Test("A refused read leaves the land Act with the Cycle unlanded and no deferred write replayed")
    func landDefersWhenTheReadIsRefused() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await deferredWriteWorld(
            journal: journal, reading: FakeReadingBoard([.failure(.rateLimited(retryAfter: nil, budget: nil))])
        )
        let (boards, staleCardID) = (world.boards, world.staleCardID)
        try await world.invocation.run()

        let types = try journal.events().map(\.type)
        #expect(types.contains(.rateBudgetExhausted))
        #expect(!types.contains(.cycleLanded))
        #expect(!types.contains(.landStep))
        #expect(!types.contains(.boardStateReposted), "the deferred Card state write waits for a completed read")
        #expect(try journal.card(id: staleCardID).boardStateVersion == nil)
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "STALE-1")))
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        #expect(issue.workflowState != scope.states[.inProgress])
    }

    // MARK: - No Act consumes another Act's observation

    @Test("A re-ready the author Act's read observed is still applied by the next build Act")
    func authorReadDoesNotConsumeAReReady() async throws {
        let world = try await makeSettleWorld(landed: false)
        let blockedIssue = try world.journal.card(id: world.blockedCardID).issueID
        #expect(try world.journal.card(id: world.blockedCardID).state == .blocked)

        // The Operator moves the Blocked Card to Todo; the author Act is the first to read it.
        let reading = FakeReadingBoard([page(objects: [object(blockedIssue, state: stateTodo, updatedAt: 40)])])
        try await reading.readThrough(world.boards)
        try await authorInvocation(world, reading: reading, authoring: ReadCountingAuthoring(reading: reading)).run()

        let afterAuthor = try world.journal.card(id: world.blockedCardID)
        #expect(afterAuthor.state == .blocked, "the author Act runs no Card, so it applies no re-ready")
        #expect(try world.journal.events(ofType: .cardRestated).count == 1)
        #expect(try world.journal.buildPendingObservations().map(\.issueID) == [blockedIssue])

        // The next build Act's own delta carries nothing new: the author's read already took the revision.
        let runID = RunID()
        guard case .claimed = try world.journal.claimActLease(act: .build, runID: runID, mode: .real) else {
            Issue.record("the build Act could not claim the lease")
            return
        }
        let buildBoard = FakeReadingBoard([page()])
        let build = DeltaRead(journal: world.journal, board: buildBoard, runID: runID, act: .build)
        guard case .read(let report) = try await build.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.reReadied.map(\.issueID) == [blockedIssue])
        #expect(try world.journal.card(id: world.blockedCardID).state == .todo)
        #expect(try world.journal.buildPendingObservations().isEmpty, "consumed once, by the Act that owns it")
    }

    @Test("A land Act's read leaves the Operator's edit to a Work Card for the build Act's Readiness Check")
    func landReadLeavesAnEditPending() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let edited = object("card-1", state: stateTodo, description: "edited by the Operator", updatedAt: 20)

        let landRunID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: landRunID, mode: .real) else {
            Issue.record("the land Act could not claim the lease")
            return
        }
        var land = DeltaRead(
            journal: journal, board: FakeReadingBoard([page(objects: [edited])]), runID: landRunID, act: .land
        )
        land.acceptsReReady = false
        guard case .read(let landReport) = try await land.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(landReport.cardChanges.map(\.card.id) == [cardID])
        #expect(try journal.releaseActLease(runID: landRunID))

        let buildRunID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: buildRunID, mode: .real) else {
            Issue.record("the build Act could not claim the lease")
            return
        }
        let build = DeltaRead(journal: journal, board: FakeReadingBoard([page()]), runID: buildRunID, act: .build)
        guard case .read(let buildReport) = try await build.perform() else {
            Issue.record("expected a read")
            return
        }

        let change = try #require(buildReport.cardChanges.first)
        #expect(change.object.description == "edited by the Operator", "the edit reaches the build Act")
        #expect(try journal.buildPendingObservations().isEmpty)
    }
}

// MARK: - Fixtures

/// A land Act over a Cycle with a Card whose state write was deferred and left behind (issue #96), with
/// the read the land Act makes first scripted by `reading`.
private struct DeferredWriteWorld {
    let boards: NightCardTestBoards
    let staleCardID: Int64
    let invocation: EngineInvocation
    let reading: FakeReadingBoard
}

private func deferredWriteWorld(
    journal: JournalStore, reading: FakeReadingBoard
) async throws -> DeferredWriteWorld {
    let runID = RunID()
    try claimLandLease(journal, runID: runID)
    let land = try LandFixture.make(journal, runID: runID, worktrees: false)

    let boards = try await makeBuildActBoards()
    _ = await boards.writing.seed(issue: "STALE-1", description: nil)
    let staleCardID = try insertReconcilerCard(
        journal, cycleID: land.cycleID, issueID: "STALE-1", repository: "extra", state: .waitingOnYou
    )
    let scope = try await BoardStateScope.resolve(using: boards.provisioning)
    let setupOutbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .land, clock: { landEpoch })
    let projection = BoardStateProjection(journal: journal, outbox: setupOutbox, scope: scope)
    _ = try journal.claimCardLease(cardID: staleCardID, runID: runID, now: landEpoch)
    await boards.writing.refuseNext(.rateLimited(retryAfter: nil, budget: nil))
    let deferOutcome = try await projection.transition(card: try journal.card(id: staleCardID), to: .inProgress)
    guard case .deferred = deferOutcome else {
        throw JournalError.cardUnknown(cardID: staleCardID)
    }
    try journal.releaseCardLease(cardID: staleCardID, runID: runID)

    let board = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
    let invocation = EngineInvocation(
        act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .forced,
        runID: runID, board: board, workspace: ReconcilerFakeWorkspace(), work: LandAct().work
    )
    return DeferredWriteWorld(boards: boards, staleCardID: staleCardID, invocation: invocation, reading: reading)
}
