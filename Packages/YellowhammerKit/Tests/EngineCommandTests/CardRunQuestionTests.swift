import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// A worker's question escalates to the Operator (roadmap P11.1; spec: bounds/escalate-a-question-to-
// the-operator): the Attempt ends `question`, consuming no Round and no Attempt, the Card moves to
// Waiting on You, the question is recorded in the Journal and posted as a comment through the Outbox,
// and the OQ60 reset sequence runs last, as on Block, so the Worktree is back at known-good with the
// Attempt's work preserved (roadmap P19.5; Landing Edge Cases Ruling 2026-10-01, OQ106).

private let questionText = "The DoD asks for a 40-hex commit, but the Worktree has no commits yet. " +
    "Should I create an empty commit first?"

/// A Dispatch seam that answers each Card's worker pass from its own scripted fixture, keyed by issue
/// id, so one lane can have one Card ask a question while another succeeds.
private struct PerCardDispatch: AgentDispatch {
    let log: CallLog
    let scripts: [String: RehearsalScript]

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.add("dispatch \(request.pass.rawValue) \(request.issueID)")
        let script = scripts[request.issueID] ?? .empty
        return try await RehearsalDispatch(script: script).dispatch(request)
    }
}

@Suite("A worker's question escalates to the Operator (P11.1)")
struct CardRunQuestionTests {
    private func makeRun(
        log: CallLog, dispatch: any AgentDispatch, resetting: RecordingAttemptResetting? = nil
    ) -> CardRun {
        CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: resetting ?? RecordingAttemptResetting(log: log)
        )
    }

    @Test("The Card ends in Waiting on You / question, consuming no Attempt, no Round, no retry")
    func endsInWaitingOnYouWithoutConsumingOrRetrying() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        // One worker pass only: no Round, no retry dispatch.
        // The reset sequence runs once, after the asking pass, and dispatches nothing.
        #expect(log.all == ["dispatch architect", "dispatch worker", "reset"])

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "question")

        let card = try world.card("BACK-1")
        #expect(card.state == .waitingOnYou)
        #expect(card.waitingReason == .question)

        let routeExclusions = try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"]))
        #expect(routeExclusions.isEmpty)
    }

    @Test("A card_question row is recorded with the question, the Attempt id, and the Outbox's client id")
    func recordsTheCardQuestion() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        let cardID = try #require(world.cardIDs["BACK-1"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        let recorded = try #require(try world.journal.latestCardQuestion(cardID: cardID))
        #expect(recorded.question == questionText)
        #expect(recorded.attemptID == attempt.id)

        let outbox = try #require(world.context.act.outbox)
        let key = "question:BACK-1:\(attempt.id)"
        #expect(recorded.commentClientID == outbox.clientID(for: key).uuidString)
    }

    @Test("The board write sets Waiting on You and the assignee, when the Operator identity is active")
    func setsWorkflowStateAndAssigneeWhenActive() async throws {
        let fixture = try OutboxJournalFixture()
        let operatorID = BoardObjectID(rawValue: "operator-1")
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), operatorIdentity: OperatorIdentity(configured: operatorID)
        )
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])
        let reading = world.context.act.board?.reading as? FakeReadingBoard
        await reading?.script(activeMember: .success(true))

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        let boards = try #require(world.boards)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState == scope.states[.waitingOnYou])
        #expect(issue.assignee == operatorID)
    }

    @Test("With the Operator identity no longer active, the state is written with no assignee")
    func writesStateWithNoAssigneeWhenInactive() async throws {
        let fixture = try OutboxJournalFixture()
        let operatorID = BoardObjectID(rawValue: "operator-1")
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), operatorIdentity: OperatorIdentity(configured: operatorID)
        )
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])
        let reading = world.context.act.board?.reading as? FakeReadingBoard
        await reading?.script(activeMember: .success(false))

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        let boards = try #require(world.boards)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState == scope.states[.waitingOnYou])
        #expect(issue.assignee == nil)
    }

    @Test("The question is posted as a comment through the Outbox, carrying the fixture's question text")
    func postsTheQuestionAsAComment() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        let boards = try #require(world.boards)
        let comment = try #require(await boards.writing.comments.first { $0.issue.rawValue == "BACK-1" })
        #expect(comment.body.contains(questionText))
    }

    @Test("The Worktree stays held, and the reset sequence ran once")
    func worktreeStaysHeldAndResetRunsOnce() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])
        let resetting = RecordingAttemptResetting(log: log)

        try await makeRun(log: log, dispatch: dispatch, resetting: resetting).run("BACK-1", in: world)

        #expect(log.all.filter { $0 == "reset" }.count == 1)
        let worktree = try #require(
            try world.journal.heldWorktree(featureID: world.context.feature.id, repository: "backend")
        )
        #expect(worktree.path.contains("backend"))

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.preservedRef == "refs/yellowhammer/attempts/test-branch/\(attempt.id)")
        #expect(attempt.preservedCommit == "preserved-\(attempt.id)")
        #expect(try cardRunLog(world.journal).contains(CardRunStep.attemptReset.rawValue))
    }

    @Test("A refused reset still leaves the Card Waiting on You with its question recorded and posted")
    func refusedResetStillSurfacesTheQuestion() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])
        let resetting = RecordingAttemptResetting(log: log, scripted: .refused(reason: "worktree not quiescent"))

        try await makeRun(log: log, dispatch: dispatch, resetting: resetting).run("BACK-1", in: world)

        let card = try world.card("BACK-1")
        #expect(card.state == .waitingOnYou)
        #expect(card.waitingReason == .question)
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "question")
        #expect(attempts[0].preservedRef == nil)
        #expect(try world.journal.latestCardQuestion(cardID: card.id)?.question == questionText)
        let boards = try #require(world.boards)
        let comment = try #require(await boards.writing.comments.first { $0.issue.rawValue == "BACK-1" })
        #expect(comment.body.contains(questionText))
        #expect(try cardRunLog(world.journal).contains(CardRunStep.attemptResetFailed.rawValue))
    }

    @Test("The reset runs with no Board: the Card is Waiting on You in the Journal")
    func resetRunsWithNoBoard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), withBoard: false)
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerQuestion])

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        #expect(try world.card("BACK-1").state == .waitingOnYou)
        #expect(log.all.filter { $0 == "reset" }.count == 1)
    }

    @Test("In a lane of two Cards, the first asking a question does not stop the second from running")
    func laneContinuesAfterAQuestion() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), cards: [("BACK-1", "backend"), ("BACK-2", "backend")]
        )
        let log = CallLog()
        let dispatch = PerCardDispatch(log: log, scripts: ["BACK-1": [.worker: .workerQuestion]])
        let run = makeRun(log: log, dispatch: dispatch)

        try await run.run("BACK-1", in: world)
        #expect(try world.card("BACK-1").state == .waitingOnYou)
        #expect(log.all.contains("reset"))

        try await run.run("BACK-2", in: world)
        #expect(try world.card("BACK-2").state == .done)

        #expect(log.all.filter { $0.hasSuffix("BACK-2") }.contains("dispatch worker BACK-2"))
        // The reset ran before the lane's next Card was dispatched.
        let resetIndex = try #require(log.all.firstIndex(of: "reset"))
        let nextIndex = try #require(log.all.firstIndex(of: "dispatch architect BACK-2"))
        #expect(resetIndex < nextIndex)
    }
}
