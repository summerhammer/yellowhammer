import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// graph-execution/handle-a-block-mid-graph, P8.9, and spec ruling OQ182 (2026-10-22): a Card ending
// Blocked or Waiting on You is recorded as a hole in the Feature — a `LaneHoleRecorded` event, and
// `JournalStore.laneHoles(cycleID:)` for later phases (the Partial Landing announcement, P10.4) to
// read — and, since OQ182, it also holds every later Card of its own same-repository sequence: they
// stay Todo, undispatched, with no Attempt spent, until it reaches Done.

/// A Dispatch seam that fails the worker pass of one named issue and completes every other pass and
/// issue normally, so a lane of several Cards can carry one that Blocks and others that run to Done.
private struct IssueScriptedDispatch: AgentDispatch {
    let failIssueID: String

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        if request.issueID == failIssueID {
            return try await RehearsalDispatch(script: [.worker: .workerFailed]).dispatch(request)
        }
        return try await RehearsalDispatch().dispatch(request)
    }
}

/// A fake ``CardRunner`` that transitions a named Card straight to Waiting on You and leaves every
/// other Card untouched, for the Waiting-on-You variant, which needs no real dispatch machinery.
private struct WaitingOnYouRunner: CardRunner {
    let waitingIssueID: String
    let log: CallLog

    func run(card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness) async throws {
        log.add(card.issueID)
        guard card.issueID == waitingIssueID else { return }
        _ = try context.act.journal.transitionCard(
            cardID: card.id, to: .waitingOnYou, waitingReason: .question,
            runID: context.act.runID, act: context.act.act, nightID: context.act.night.id
        )
    }
}

@Suite("Lane holes (P8.9)")
struct LaneHoleTests {
    @Test("A Blocked Card holds the later Cards of its sequence; only it is recorded as a hole")
    func blockedCardHoldsTheRestOfTheLane() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        try await initReconcilerGitRepo(at: worktrees.appending(component: "backend"), branch: buildActBranch.name)
        let world = try await makeCardRunWorld(
            journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend"), ("BACK-3", "backend")],
            worktreePath: { worktrees.appending(component: $0).path(percentEncoded: false) }
        )
        let dispatch = IssueScriptedDispatch(failIssueID: "BACK-1")
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 1, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        let board = try #require(world.context.act.board)
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: world.runID, board: board, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: run).work
        )

        try await invocation.run()

        #expect(try world.card("BACK-1").state == .blocked)
        // BACK-1 holds its sequence: BACK-2 and BACK-3 stay Todo, undispatched.
        #expect(try world.card("BACK-2").state == .todo)
        #expect(try world.card("BACK-3").state == .todo)

        #expect(try world.attempts("BACK-2").isEmpty)
        #expect(try world.attempts("BACK-3").isEmpty)

        let holeEvents = try journal.events(ofType: .laneHoleRecorded)
        #expect(holeEvents.count == 1)
        guard case .laneHoleRecorded(_, let issueID, let repository, let state) = try #require(holeEvents.first?.event)
        else {
            Issue.record("expected laneHoleRecorded")
            return
        }
        #expect(issueID == "BACK-1")
        #expect(repository == "backend")
        #expect(state == .blocked)

        let holes = try journal.laneHoles(cycleID: world.context.cycleID)
        #expect(holes.map(\.issueID) == ["BACK-1"])
    }

    @Test("A Waiting-on-You Card holds the later Cards of its sequence; only it is recorded as a hole")
    func waitingOnYouCardHoldsTheRestOfTheLane() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        try await initReconcilerGitRepo(at: worktrees.appending(component: "backend"), branch: buildActBranch.name)
        let world = try await makeCardRunWorld(
            journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend")], withBoard: false,
            worktreePath: { worktrees.appending(component: $0).path(percentEncoded: false) }
        )
        let log = CallLog()
        let runner = WaitingOnYouRunner(waitingIssueID: "BACK-1", log: log)
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: world.runID, board: nil, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: runner).work
        )

        try await invocation.run()

        #expect(try world.card("BACK-1").state == .waitingOnYou)
        // BACK-1 holds its sequence: the fake runner was invoked for BACK-1 only, never for BACK-2.
        #expect(log.all == ["BACK-1"])
        #expect(try world.card("BACK-2").state == .todo)

        let holeEvents = try journal.events(ofType: .laneHoleRecorded)
        #expect(holeEvents.count == 1)
        guard case .laneHoleRecorded(_, let issueID, _, let state) = try #require(holeEvents.first?.event) else {
            Issue.record("expected laneHoleRecorded")
            return
        }
        #expect(issueID == "BACK-1")
        #expect(state == .waitingOnYou)

        let holes = try journal.laneHoles(cycleID: world.context.cycleID)
        #expect(holes.map(\.issueID) == ["BACK-1"])
    }
}
