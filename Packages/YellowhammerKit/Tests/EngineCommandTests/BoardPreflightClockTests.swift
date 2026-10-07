import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Synchronization
import Testing

// OQ93(f) as widened by OQ136: every halt in which no Act read the board spends no
// `overdue_nights_max`. An Act refused at the board preflight — identity or board scope — reads no
// Card and advances no clock, whichever Act it is; OQ135: a Worktree-name collision is thrown later,
// after the build Act's clock ran, so it still counts.

private enum PreflightRefusal: CaseIterable, CustomTestStringConvertible, Sendable {
    case authorization, boardScope

    var testDescription: String {
        switch self {
        case .authorization: "authorization refused"
        case .boardScope: "board scope unresolved"
        }
    }
}

private final class WorkFlag: Sendable {
    private let storage = Mutex(false)
    var ran: Bool { storage.withLock { $0 } }
    func set() { storage.withLock { $0 = true } }
}

/// A Card Waiting on You whose clock stands AT the bound (`unansweredNightsMax` is 1, so one more
/// counted Night fires it), in an open Cycle, with its Feature Issue's Card seeded on the board.
private struct ClockWorld {
    static let unansweredNightsMax = 1

    let journal: JournalStore
    let boards: NightCardTestBoards
    let cardID: Int64
    let cycleID: Int64

    init(journal: JournalStore) async throws {
        self.journal = journal
        boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .waitingOnYou
        )
        self.cardID = cardID
        try journal.write { db in
            try db.execute(
                sql: "UPDATE card SET unanswered_nights = ? WHERE id = ?",
                arguments: [Self.unansweredNightsMax, cardID]
            )
        }
    }

    func refuse(_ refusal: PreflightRefusal) async -> FakeReadingBoard {
        let reading = FakeReadingBoard([])
        switch refusal {
        case .authorization:
            await reading.script(identity: .failure(.notAuthenticated("sign-in expired")))
        case .boardScope:
            await boards.provisioning.remove(state: BoardProvisioner.blockedState, team: teamID)
        }
        return reading
    }

    /// An Act whose work is the Cards' clock, the one step OQ136 says a refused Act must not reach.
    func invocation(_ act: Act, reading: FakeReadingBoard, workRan: WorkFlag) -> EngineInvocation {
        let cycleID = cycleID
        return EngineInvocation(
            act: act, mode: .real, nightStart: nightCardNightStart, journal: journal, trigger: .forced,
            runID: RunID(),
            board: ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning),
            work: { context in
                workRan.set()
                try await UnansweredCardClock.run(
                    cycleIDs: [cycleID], unansweredNightsMax: Self.unansweredNightsMax, context: context
                )
            }
        )
    }
}

@Suite("Board preflight spends no clock (OQ136)")
struct BoardPreflightClockTests {
    private static let acts: [Act] = [.author, .build, .land]

    @Test(
        "A refused Act leaves a Card at the unanswered-Nights bound untouched",
        arguments: PreflightRefusal.allCases, acts
    )
    fileprivate func refusedActAdvancesNoClock(refusal: PreflightRefusal, act: Act) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await ClockWorld(journal: journal)
        let reading = await world.refuse(refusal)
        let workRan = WorkFlag()

        await #expect(throws: (any Error).self) {
            try await world.invocation(act, reading: reading, workRan: workRan).run()
        }

        #expect(!workRan.ran)
        let card = try journal.card(id: world.cardID)
        #expect(card.unansweredNights == ClockWorld.unansweredNightsMax, "the clock did not move")
        #expect(card.state == .waitingOnYou)
        #expect(try journal.events(ofType: .cardUnansweredBoundFired).isEmpty)
        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState == nil, "no board write touched the Card")
    }

    @Test("Control: on a complete, authorized board the same setup advances the clock and blocks the Card",
          arguments: acts)
    func completeBoardAdvancesTheClock(act: Act) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await ClockWorld(journal: journal)
        let workRan = WorkFlag()

        try await world.invocation(act, reading: FakeReadingBoard([]), workRan: workRan).run()

        #expect(workRan.ran)
        #expect(try journal.events(ofType: .cardUnansweredBoundFired).count == 1)
        let card = try journal.card(id: world.cardID)
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.replyOverdue.rawValue)
        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState != nil, "the auto-Block was written to the board")
    }

    @Test("OQ135: a collision-halted build Act still advanced the Waiting on You Card's clock")
    func collisionHaltedBuildActStillCountsTheNight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let todoCard = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let waitingCard = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .waitingOnYou
        )
        let workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-buildact-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspaceDirectory) }
        let workspace = BuildActFakeWorkspace(baseDirectory: workspaceDirectory)
        let path = "/tmp/yh-buildact-fixture/backend"
        workspace.scriptReportedBranch("somebody/else", forRepositoryPath: path)
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID,
            repositories: ProjectRepositories(workingRepos: [Repo(name: "backend", path: path, role: .backend)]),
            workspace: workspace, work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        await #expect(throws: BuildActError.self) { try await invocation.run() }

        #expect(try journal.card(id: todoCard).state == .todo)
        #expect(try journal.card(id: waitingCard).unansweredNights == 1, "the Night was counted before the halt")
        #expect(try journal.events(ofType: .worktreeNameCollision).count == 1)
    }
}
