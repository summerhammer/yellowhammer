import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// graph-execution/run-a-card (roadmap P8.4): every ending that is not a success, and Routes that never
// dispatch. The policies around them — retry, the Attempt budget, the Round loop — are later items; here
// the Attempt is ended faithfully and the Card returned to Ready.

@Suite("Card run endings")
struct CardRunFailureTests {
    private func makeRun(
        log: CallLog, script: [RunPass: RehearsalResultFixture] = [:], resolver: RouteResolver = cardRunResolver()
    ) -> CardRun {
        CardRun(
            resolver: resolver, dispatch: LoggingDispatch(log: log, script: script),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3
        )
    }

    @Test("An empty worker result file is Crashed-Unknown: consumed, no Route excluded, the Card back to Ready")
    func emptyWorkerResultIsCrashedUnknown() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(log: log, script: [.worker: .workerEmpty]).run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "Crashed-Unknown")
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])).isEmpty)
        #expect(try world.card("BACK-1").state == .todo)
    }

    @Test("A worker that reports failure is a hard failure: the Route is excluded, the Card back to Ready")
    func reportedWorkerFailureIsAHardFailure() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())

        try await makeRun(log: CallLog(), script: [.worker: .workerFailed]).run("BACK-1", in: world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "hard failure")
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])) == [cardRunOpus])
        #expect(try world.card("BACK-1").state == .todo)
    }

    @Test("A worker's question ends the Attempt without consuming it: no Route excluded, the Card back to Ready")
    func workerQuestionEndsTheAttemptWithoutExcludingTheRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(log: log, script: [.worker: .workerQuestion]).run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "question")
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])).isEmpty)
        #expect(try world.card("BACK-1").state == .todo)
    }

    @Test("Zero candidate Routes Block the Card: no Attempt, and nothing is dispatched")
    func zeroCandidatesBlockTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let resolver = cardRunResolver(probe: { _ in .excluded(reason: "the Probe failed") })

        try await makeRun(log: log, resolver: resolver).run("BACK-1", in: world)

        #expect(log.all.isEmpty)
        #expect(try world.attempts("BACK-1").isEmpty)
        #expect(try world.card("BACK-1").state == .blocked)
        #expect(try cardRunLog(world.journal).contains("architect") == false)
        #expect(try world.journal.currentCardLease(cardID: try #require(world.cardIDs["BACK-1"])) == nil)
        let boards = try #require(world.boards)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState == scope.states[.blocked])
    }

    @Test("A Route the machine cannot run (agent CLI unknown or not installed) is that Attempt's hard failure")
    func unrunnableRouteIsARouteFailureNotAnEngineFault() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: RefusingDispatch(log: log), check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3
        )

        try await run.run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "hard failure")
        #expect(try world.card("BACK-1").state == .todo)
    }

    @Test("A Card whose repository holds no Worktree is an engine fault, and spends no Attempt")
    func missingWorktreeIsAnEngineFault() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), cards: [("MOB-1", "mobile")])
        let run = makeRun(log: CallLog())
        let card = try world.card("MOB-1")
        try world.journal.write { db in
            try db.execute(sql: "UPDATE worktree SET repository = 'other'")
        }

        await #expect(throws: CardRunError.worktreeMissing(featureID: world.context.feature.id, repository: "mobile")) {
            try await run.run(
                card: card, in: RepoLane(repository: "mobile", cards: [card]), context: world.context,
                readiness: CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [])
            )
        }
        #expect(try world.attempts("MOB-1").isEmpty)
        #expect(try world.journal.currentCardLease(cardID: card.id) == nil)
    }
}
