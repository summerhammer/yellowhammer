import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// shift-scheduling/open-and-close-the-night-card (P5.7): the first Act of a Project's Night creates
// that Project's Night Card before any work; the land firing at `night_end` completes it with the
// Night Summary, whether or not work happened; creation and completion go through the Outbox so a
// crashed and resumed Act cannot create two.

let nightCardNightStart = NightStart(rawValue: "2026-09-15")!
let teamID = BoardObjectID(rawValue: "team-1")

struct NightCardJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-night-card-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.openSeeded(configurationDirectory: directory, projectID: projectID)
    }
}

/// Seeds a team with a complete disposition-label catalogue (every declared child of Object Type and
/// Block Reason, since ``DispositionLabels`` requires all of them) and returns the minted label ids,
/// keyed by name.
@discardableResult
func seedDispositionLabels(
    on board: FakeProvisioningBoard, team: BoardObjectID, includeNightCard: Bool = true
) async throws -> [String: BoardObjectID] {
    await board.seed(label: BoardProvisioner.objectTypeGroup, team: team, isGroup: true)
    let objectTypeGroupID = try await board.labels(team: team).first {
        $0.name == BoardProvisioner.objectTypeGroup && $0.isGroup
    }!.id
    var ids: [String: BoardObjectID] = [:]
    for child in BoardProvisioner.objectTypeChildren where child != "Night Card" || includeNightCard {
        await board.seed(label: child, team: team, parent: objectTypeGroupID)
    }
    await board.seed(label: BoardProvisioner.blockReasonGroup, team: team, isGroup: true)
    let blockReasonGroupID = try await board.labels(team: team).first {
        $0.name == BoardProvisioner.blockReasonGroup && $0.isGroup
    }!.id
    for child in BoardProvisioner.blockReasonChildren {
        await board.seed(label: child, team: team, parent: blockReasonGroupID)
    }
    for label in try await board.labels(team: team) {
        ids[label.name] = label.id
    }
    return ids
}

/// The boards ``makeBoards()`` hands a test: a provisioning board seeded with every disposition
/// label plus an unstarted "Todo" and a completed "Done" state, a Writing board with no issues yet,
/// and the minted label ids, keyed by name.
struct NightCardTestBoards {
    let provisioning: FakeProvisioningBoard
    let writing: FakeWritingBoard
    let ids: [String: BoardObjectID]
}

func makeBoards(includeNightCard: Bool = true) async throws -> NightCardTestBoards {
    let boardTeam = BoardTeam(id: teamID, key: "ENG", name: "Engineering")
    let scope = BoardProjectScope(id: BoardObjectID(rawValue: "proj-1"), name: "Yellowhammer", teams: [boardTeam])
    let provisioning = FakeProvisioningBoard(project: scope)
    let ids = try await seedDispositionLabels(on: provisioning, team: teamID, includeNightCard: includeNightCard)
    await provisioning.seed(state: "Todo", team: teamID, category: .unstarted)
    await provisioning.seed(state: "Done", team: teamID, category: .completed)
    return NightCardTestBoards(provisioning: provisioning, writing: FakeWritingBoard(), ids: ids)
}

private final class Box<Value: Sendable>: Sendable {
    private let storage: Mutex<Value?>
    init() { storage = Mutex(nil) }
    func set(_ value: Value) { storage.withLock { $0 = value } }
    var value: Value? { storage.withLock { $0 } }
}

@Suite("Open and close the Night Card")
struct NightCardTests {
    @Test("The first Act opens the Night Card before any work")
    func firstActOpensNightCardBeforeWork() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let ids = boards.ids
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                let liveIssues = await writing.liveIssues
                #expect(liveIssues.count == 1)
                let issue = try #require(liveIssues.first)
                #expect(issue.title == "Night \(nightCardNightStart)")
                #expect(issue.labels.contains(try #require(ids["Night Card"])))
                #expect(issue.parent == nil)
                let description = try #require(issue.description)
                #expect(description.contains(ManagedBlockFence.start))
                #expect(description.contains("**Night Summary:** the Night is open"))
                #expect(context.night.nightCardIssueID == issue.id.rawValue)
            }
        )
        try await invocation.run()

        let night = try #require(try journal.currentNight())
        #expect(night.nightCardIssueID != nil)
        let events = try journal.events().map(\.type)
        #expect(events == [.nightOpened, .actStarted, .nightCardOpened, .actEnded])
    }

    @Test("A second Act of the same Night creates nothing")
    func secondActCreatesNothing() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()
        try await EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()

        #expect(await writing.createIssueCalls == 1)
        #expect(await writing.liveIssues.count == 1)
    }

    @Test("A build Act of a Night whose card already exists reads nothing from provisioning")
    func existingCardSkipsProvisioningReads() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()

        let readsAfterFirstAct = await provisioning.reads
        let createIssueCallsAfterFirstAct = await writing.createIssueCalls

        try await EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, work: { _ in }
        ).run()

        // The card already exists: `open` returns `.alreadyRecorded` before it ever resolves the
        // scope, so a build Act of an already-open Night makes zero provisioning reads.
        #expect(await provisioning.reads == readsAfterFirstAct)
        #expect(await writing.createIssueCalls == createIssueCallsAfterFirstAct)
    }

    @Test("An idle Night still has a Night Card")
    func idleNightStillHasNightCard() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)
        let run = RunID()

        // The Feature Roll-up (P12.3) maintains the in-flight Feature's own Managed Block on every
        // Act, idle or not — its Feature Issue needs a fenced description to post against.
        await writing.seed(issue: "FEATURE-1", description: ManagedBlockFence.initialDescription(rendered: ""))

        // A todo Card makes the author trigger unmet: there is already dispatchable work.
        try journal.write { db in
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000).formatted(.iso8601)
            try db.execute(
                sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
                arguments: ["FEATURE-1", "selected", timestamp]
            )
            let featureID = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)", arguments: [featureID, timestamp]
            )
            let cycleID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [cycleID, "CARD-1", "main", "card", 1, CardState.todo.rawValue, 0, timestamp]
            )
        }

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .scheduled, runID: run, board: board,
            work: { _ in Issue.record("Work should not run") }
        )
        try await invocation.run()

        let events = try journal.events().map(\.type)
        #expect(
            events ==
                [.nightOpened, .actStarted, .nightCardOpened, .actIdle, .managedBlockWritten, .actEnded]
        )
        // The Night Card and the in-flight Feature's own Roll-up block, seeded above.
        #expect(await writing.liveIssues.count == 2)
    }

    @Test("The land firing at night_end completes the Night Card")
    func landAtNightEndCompletesNightCard() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board, work: { _ in }
        )
        try await invocation.run()

        let issue = try #require(await writing.liveIssues.first)
        let scope = try await NightCardScope.resolve(using: provisioning)
        #expect(issue.workflowState == scope.completedState)
        let description = try #require(issue.description)
        #expect(description.contains("**Completed:**"))
        #expect(description.contains("**Verdict:** no decisions waiting · did not advance · closed"))

        let events = try journal.events().map(\.type)
        let nightClosedIndex = try #require(events.firstIndex(of: .nightClosed))
        let nightCardCompletedIndex = try #require(events.firstIndex(of: .nightCardCompleted))
        #expect(nightClosedIndex < nightCardCompletedIndex)
        #expect(try journal.currentNight() == nil)
    }

    @Test("The idle verdict is carried onto the completed Night Card")
    func idleVerdictIsCarried() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            work: { context in
                try journal.recordAuthoringNoWorkAvailable(
                    nightID: context.night.id, act: context.act, runID: context.runID
                )
            }
        )
        try await invocation.run()

        let issue = try #require(await writing.liveIssues.first)
        let description = try #require(issue.description)
        #expect(description.contains("**Verdict:** no decisions waiting · did not advance — idle · closed"))
        let events = try journal.events()
        #expect(events.map(\.type).contains(.authoringNoWorkAvailable))
    }

    @Test("A deferred completion is replayed by a later Act")
    func deferredCompletionIsReplayed() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            work: { _ in
                await writing.refuseNext(.unreachable("simulated outage"))
            }
        ).run()

        #expect(try journal.currentNight() == nil)
        #expect(try journal.pendingOutboxEntries().count == 2)
        #expect(try journal.events().map(\.type).contains(.nightCardCompleted) == false)

        let updatesBefore = await writing.updateCalls
        let replayed = Box<Bool>()
        try await EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { context in
                guard let outbox = context.outbox else {
                    Issue.record("Expected an Outbox on the context")
                    return
                }
                _ = try await outbox.deliverPending()
                replayed.set(true)
            }
        ).run()

        #expect(replayed.value == true)
        #expect(try journal.pendingOutboxEntries().isEmpty)
        // One updateIssue call rewrites the description (the fenced Managed Block), one moves the
        // workflow state.
        #expect(await writing.updateCalls == updatesBefore + 2)
    }

    @Test("open fails when the board refuses for good")
    func openFailsWhenBoardRefuses() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let provisioning = boards.provisioning
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: provisioning)
        await writing.refuseNext(.refused("no"))

        let invocation = EngineInvocation(
            act: .author, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board,
            work: { _ in Issue.record("Work should not run") }
        )
        await #expect(throws: (any Error).self) {
            try await invocation.run()
        }

        let events = try journal.events().map(\.type)
        // A board is wired, but the Night Card was never opened, so the halted event (P12.5) cannot be
        // recorded on it first: `notificationDeliveryFailed` follows `actIncomplete` instead of a post.
        #expect(events.contains(.actIncomplete))
        #expect(events.last == .notificationDeliveryFailed)
        #expect(try journal.currentNight()?.nightCardIssueID == nil)
    }
}
