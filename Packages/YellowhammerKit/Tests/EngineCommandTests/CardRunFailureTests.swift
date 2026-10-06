import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// graph-execution/run-a-card (roadmap P8.4): every ending that is not a success, and Routes that never
// dispatch. These fixtures use a single-Route table and `attemptsPerWorkCard: 3`, so a consuming ending that
// excludes its Route (hard failure) leaves no candidate for the retry (roadmap P8.7) to resolve, and the
// Card Blocks `route failure` rather than returning to Ready — Crashed-Unknown excludes nothing, so it
// retries on the same Route until the Attempt budget itself is spent. The Round loop's own Attempt-budget
// policy is CardRunCheckRoundTests.swift and CardRunReviewRoundTests.swift.

@Suite("Card run endings")
struct CardRunFailureTests {
    private func makeRun(
        log: CallLog, script: RehearsalScript = .empty, resolver: RouteResolver = cardRunResolver()
    ) -> CardRun {
        CardRun(
            resolver: resolver, dispatch: LoggingDispatch(log: log, script: script),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting()
        )
    }

    @Test("An empty worker result file is Crashed-Unknown, excludes nothing, and retries the same Route until spent")
    func emptyWorkerResultIsCrashedUnknown() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(log: log, script: [.worker: .workerEmpty]).run("BACK-1", in: world)

        #expect(log.all == [
            "dispatch architect", "dispatch worker", "dispatch architect", "dispatch worker",
            "dispatch architect", "dispatch worker"
        ])
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 3)
        #expect(attempts.allSatisfy { $0.result == "Crashed-Unknown" && $0.route == cardRunOpus })
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])).isEmpty)
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        // The final Attempt of the epoch ended Crashed-Unknown: a dying host, not the model's fault
        // (Attempt, Block and Reset Ruling 2026-09-19, OQ58/59).
        #expect(card.blockReason == BlockReason.hostCrash.rawValue)
    }

    @Test("A worker that reports failure is a hard failure: the Route is excluded, and with none left the Card Blocks")
    func reportedWorkerFailureIsAHardFailure() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())

        try await makeRun(log: CallLog(), script: [.worker: .workerFailed]).run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "hard failure")
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])) == [cardRunOpus])
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.routeFailure.rawValue)
        // Blocked because the routing table has no candidate left, not because the Attempt budget was
        // spent: no `attempts-exhausted` step (unlike ``emptyWorkerResultIsCrashedUnknown``, above).
        #expect(!(try cardRunLog(world.journal).contains(CardRunStep.attemptsExhausted.rawValue)))
    }

    @Test(
        "A worker's question ends the Attempt without consuming it: no Route excluded, the Card to Waiting on You"
    )
    func workerQuestionEndsTheAttemptWithoutExcludingTheRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(log: log, script: [.worker: .workerQuestion]).run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "question")
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])).isEmpty)
        let card = try world.card("BACK-1")
        #expect(card.state == .waitingOnYou)
        #expect(card.waitingReason == .question)
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
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect"])
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "hard failure")
        // The excluded Route leaves no candidate to retry on: Blocked, not a second Attempt.
        #expect(try world.card("BACK-1").state == .blocked)
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
        // The Card was still Ready/Todo when the fault struck: the Lease was released, not left to
        // expire, so nothing needs the next Act's Expired Lease Sweep (issue #173).
        #expect(!(try cardRunSteps(world.journal, cardID: card.id)).contains { $0.step == .leaseLeftToExpire })
    }
}
