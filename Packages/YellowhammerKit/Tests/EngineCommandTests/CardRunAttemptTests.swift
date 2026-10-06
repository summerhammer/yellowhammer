import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// graph-execution/run-a-card, Attempts and hard failure (roadmap P8.7): a hard failure, a Crashed-Unknown
// or a rounds-exhausted ending, with the Attempt budget not yet spent, dispatches a fresh Attempt from the
// same held Lease rather than returning the Card to Ready; the Card Blocks only once the Attempt budget
// itself is spent. Nothing here asserts model quality: the fixture strings are carried through as given,
// and wiring and arithmetic are all that is checked.

private func twoRouteResolver() -> RouteResolver {
    cardRunResolver(table: RoutingTable(entries: [
        RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
    ]))
}

@Suite("Card run, Attempts and hard failure (P8.7)")
struct CardRunAttemptTests {
    // MARK: - a. hard failure then success, on a different Route

    @Test("A hard failure retries on a different Route; the Card never bounces through Ready between Attempts")
    func hardFailureThenSuccessRetriesOnADifferentRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = SequencedDispatch(log: log, sequences: [.worker: [.workerFailed, .workerCompleted]])
        let resetting = RecordingAttemptResetting(log: log)
        let run = CardRun(
            resolver: twoRouteResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: resetting
        )

        try await run.run("BACK-1", in: world)

        // The reset runs between the first Attempt's last pass and the second Attempt's architect
        // (OQ60): no reset before the first Attempt, and exactly one between the two.
        #expect(log.all == [
            "dispatch architect", "dispatch worker", "reset", "dispatch architect", "dispatch worker", "check",
            "dispatch reviewer"
        ])
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 2)
        #expect(attempts[0].result == "hard failure")
        #expect(attempts[0].route == cardRunOpus)
        #expect(attempts[1].result == "success")
        #expect(attempts[1].route == cardRunFallback)
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])) == [cardRunOpus])
        #expect(try world.card("BACK-1").state == .done)

        // Never bounced back to Ready between the two Attempts: In Progress once, then Done.
        let story = try cardRunLog(world.journal)
        #expect(story.filter { $0 == "→ In Progress" } == ["→ In Progress"])
        #expect(!story.contains("→ Todo"))

        // The second Attempt's passes carry the preserved work as context; the first Attempt's do not
        // (OQ60): a new Attempt starts fresh, never as a rescue, but the reset hands it what came before.
        let architectRequests = dispatch.requests.passes(.architect)
        #expect(architectRequests.count == 2)
        #expect(architectRequests[0].instruction.cardInstruction?.payloads.wip == nil)
        #expect(architectRequests[1].instruction.cardInstruction?.payloads.wip?.commit == "preserved-\(attempts[0].id)")

        let steps = try cardRunLog(world.journal)
        #expect(steps.contains(CardRunStep.attemptReset.rawValue))

        // The preserved ref is recorded against the prior (first) Attempt's own row.
        let history = try world.journal.attemptHistory(cardID: try #require(world.cardIDs["BACK-1"]))
        let recordedFirst = try #require(history.attempts.first { $0.id == attempts[0].id })
        #expect(recordedFirst.preservedRef == "refs/yellowhammer/attempts/test-branch/\(attempts[0].id)")
        #expect(recordedFirst.preservedCommit == "preserved-\(attempts[0].id)")
    }

    // MARK: - b. hard failures until the Attempt budget is spent, Routes still available

    @Test("Hard failures spend the Attempt budget with Routes still available: Blocked, attempts-exhausted recorded")
    func hardFailuresSpendTheBudgetWithRoutesStillAvailable() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = SequencedDispatch(log: log, sequences: [.worker: [.workerFailed, .workerFailed]])
        let run = CardRun(
            resolver: twoRouteResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 2,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker", "dispatch architect", "dispatch worker"])
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 2)
        #expect(attempts.map(\.result) == ["hard failure", "hard failure"])
        #expect(attempts.map(\.route) == [cardRunOpus, cardRunFallback])
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.hardFailure.rawValue)
        let steps = try cardRunLog(world.journal)
        #expect(steps.contains(CardRunStep.attemptsExhausted.rawValue))
    }

    // MARK: - c. exclusion leaves no Route while budget remains

    @Test("A single-Route table excludes the only Route on the first hard failure: Blocked, no attempts-exhausted step")
    func exclusionLeavesNoRouteWhileBudgetRemains() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log, script: [.worker: .workerFailed]),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "hard failure")
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.hardFailure.rawValue)
        let steps = try cardRunLog(world.journal)
        #expect(!steps.contains(CardRunStep.attemptsExhausted.rawValue))
    }

    // MARK: - d. Crashed-Unknown retries the same Route

    @Test("Crashed-Unknown excludes nothing: the retry lands on the same Route until the budget is spent")
    func crashedUnknownRetriesTheSameRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let run = CardRun(
            resolver: twoRouteResolver(), dispatch: LoggingDispatch(log: log, script: [.worker: .workerEmpty]),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 2,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 2)
        #expect(attempts.allSatisfy { $0.result == "Crashed-Unknown" && $0.route == cardRunOpus })
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])).isEmpty)
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        // The final Attempt of the epoch ended Crashed-Unknown: `host crash`, not `hard failure`.
        #expect(card.blockReason == BlockReason.hostCrash.rawValue)

        let consumption = try world.journal.attemptHistory(cardID: try #require(world.cardIDs["BACK-1"]))
            .consumption(inEpoch: card.budgetEpoch)
        #expect(consumption.crashedUnknown == 2)
        #expect(consumption.routesFailed == 0)
    }

    // MARK: - d'. a prior Attempt the engine stopped blocks `engine stop`, not `host crash` (OQ92)

    @Test("A prior Attempt the engine stopped, with the budget already spent, Blocks engine stop, not host crash")
    func priorEngineStoppedAttemptBlocksEngineStop() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let log = CallLog()
        // A dead run's Attempt the Expired Lease Sweep already classified as engine-stopped, seeded
        // directly rather than through a full reclaim (loop-state/reclaim-an-expired-lease, P8.10).
        let seeded = try world.journal.recordAttempt(
            cardID: cardID, route: cardRunOpus, runID: world.runID, act: .build, nightID: world.context.act.night.id
        )
        _ = try world.journal.endAttempt(
            attemptID: seeded.id, ending: .crashedUnknown(.engineStopped(cause: "heartbeat failed")),
            runID: world.runID, act: .build, nightID: world.context.act.night.id
        )
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log, script: .empty),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 1,
            resetting: RecordingAttemptResetting(log: log)
        )

        try await run.run("BACK-1", in: world)

        // The budget was already spent before this run dispatched anything: only the pre-Block reset
        // ran (OQ60), never architect or worker.
        #expect(log.all == ["reset"])
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.engineStop.rawValue)
        let steps = try cardRunLog(world.journal)
        #expect(steps.contains(CardRunStep.attemptsExhausted.rawValue))
    }

    // MARK: - e. both budgets: a Round consumes no Attempt, an Attempt consumes no Round

    @Test("Rounds-exhausted retries on a different Route while the Attempt budget has room, then Blocks by reviewer")
    func bothBudgetsRule() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let dispatch = SequencedDispatch(
            log: log, sequences: [.reviewer: [.reviewerChangesRequested, .reviewerChangesRequested]]
        )
        let run = CardRun(
            resolver: twoRouteResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 1, attemptsPerWorkCard: 2,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 2)
        #expect(attempts.map(\.result) == ["rounds-exhausted", "rounds-exhausted"])
        #expect(attempts.map(\.route) == [cardRunOpus, cardRunFallback])
        // Each Attempt has exactly its own one Round: a Round never spans two Attempts.
        #expect(attempts.allSatisfy { $0.rounds.count == 1 })
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.blockedByReviewer.rawValue)
    }

    // MARK: - f. a question consumes nothing and never retries

    @Test("A question ends the run without a retry and consumes nothing: a later run still dispatches")
    func questionConsumesNothingAndDoesNotRetry() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let firstRun = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log, script: [.worker: .workerQuestion]),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 1,
            resetting: RecordingAttemptResetting()
        )

        try await firstRun.run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker"])
        var attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "question")
        let firstCard = try world.card("BACK-1")
        #expect(firstCard.state == .waitingOnYou)
        #expect(firstCard.waitingReason == .question)

        // attemptsPerWorkCard=1, but the question consumed none of it: the next run still dispatches.
        let secondLog = CallLog()
        let secondRun = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: secondLog),
            check: RecordingCheck(log: secondLog), checks: ["backend": .none], reviewRoundsMax: 2,
            attemptsPerWorkCard: 1,
            resetting: RecordingAttemptResetting()
        )
        try await secondRun.run("BACK-1", in: world)

        #expect(secondLog.all == ["dispatch architect", "dispatch worker", "check", "dispatch reviewer"])
        attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 2)
        #expect(attempts[1].result == "success")
        #expect(try world.card("BACK-1").state == .done)
    }

    // MARK: - g. the budget guard, before any Attempt of this run

    @Test("A Card whose epoch already holds the Attempt budget dispatches nothing; a reset lets it dispatch again")
    func budgetGuardBeforeAnyAttemptOfThisRun() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        for offset in 0..<2 {
            let seeded = try world.journal.recordAttempt(cardID: cardID, route: cardRunOpus, runID: world.runID)
            try world.journal.endAttempt(
                attemptID: seeded.id, ending: .hardFailure(.exitStatus(Int32(offset + 1))), runID: world.runID
            )
        }
        let log = CallLog()
        let resetLog = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log), check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 2,
            resetting: RecordingAttemptResetting(log: resetLog)
        )

        try await run.run("BACK-1", in: world)

        #expect(log.all.isEmpty)
        // Still runs the reset even though this run dispatched no Attempt of its own (OQ60): recorded
        // against the Card's last Attempt in history.
        #expect(resetLog.all == ["reset"])
        #expect(try world.attempts("BACK-1").count == 2)
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.hardFailure.rawValue)
        #expect(try cardRunLog(world.journal).contains(CardRunStep.attemptsExhausted.rawValue))

        // A fresh budget epoch (an Override pin change in triage, in the product) lets the Card dispatch.
        _ = try world.journal.resetBudgetEpoch(
            cardID: cardID, reason: "test reset", runID: world.runID, act: world.context.act.act,
            nightID: world.context.act.night.id
        )
        try world.journal.transitionCard(
            cardID: cardID, to: .todo, runID: world.runID, act: world.context.act.act,
            nightID: world.context.act.night.id
        )
        let secondLog = CallLog()
        let secondRun = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: secondLog),
            check: RecordingCheck(log: secondLog), checks: ["backend": .none], reviewRoundsMax: 2,
            attemptsPerWorkCard: 2,
            resetting: RecordingAttemptResetting()
        )
        try await secondRun.run("BACK-1", in: world)

        #expect(!secondLog.all.isEmpty)
        #expect(try world.attempts("BACK-1").count == 3)
    }
}

// Section h. the reset sequence (Attempt, Block and Reset Ruling 2026-09-19, OQ60) is
// CardRunResetTests.swift, split out to keep this file under the length limit.
