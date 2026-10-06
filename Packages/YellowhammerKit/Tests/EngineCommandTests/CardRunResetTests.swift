import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// The fence → WIP-commit → preserve → reset sequence (Attempt, Block and Reset Ruling 2026-09-19,
// OQ60): a new Attempt starts fresh, never as a rescue. Split out of CardRunAttemptTests.swift to
// keep that file under the length limit.

private func twoRouteResolver() -> RouteResolver {
    cardRunResolver(table: RoutingTable(entries: [
        RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
    ]))
}

@Suite("Card run, the reset sequence (OQ60)")
struct CardRunResetTests {
    @Test("A failing reset before a retry never dispatches the new Attempt: Card Ready, attempt-reset-failed recorded")
    func failingResetBeforeRetryStopsTheRunAtReady() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let resetting = RecordingAttemptResetting(log: log, scripted: .refused(reason: "Worktree not quiescent"))
        let run = CardRun(
            resolver: twoRouteResolver(), dispatch: LoggingDispatch(log: log, script: [.worker: .workerFailed]),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: resetting
        )

        try await run.run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker", "reset"])
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "hard failure")
        let card = try world.card("BACK-1")
        #expect(card.state == .todo)
        let steps = try cardRunLog(world.journal)
        #expect(steps.contains(CardRunStep.attemptResetFailed.rawValue))
        #expect(!steps.contains(CardRunStep.attemptReset.rawValue))
    }

    @Test("A failing reset on the Block path still Blocks the Card, and records attempt-reset-failed")
    func failingResetOnBlockStillBlocks() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let resetting = RecordingAttemptResetting(log: log, scripted: .failed(reason: "git reset exited 1"))
        // attemptsPerWorkCard: 1 so the first hard failure spends the budget outright: the retryOrBlock
        // Block path runs, not a retry.
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log, script: [.worker: .workerFailed]),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 1,
            resetting: resetting
        )

        try await run.run("BACK-1", in: world)

        #expect(log.all.contains("reset"))
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.routeFailure.rawValue)
        let steps = try cardRunLog(world.journal)
        #expect(steps.contains(CardRunStep.attemptResetFailed.rawValue))
    }

    @Test("A Round is not a new Attempt: no reset runs between the worker's Rounds on the same Attempt")
    func noResetBetweenRounds() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()
        let sequences: [RunPass: [RehearsalResultFixture]] = [
            .reviewer: [.reviewerChangesRequested, .reviewerApproved]
        ]
        let dispatch = SequencedDispatch(log: log, sequences: sequences)
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 2,
            resetting: RecordingAttemptResetting(log: log)
        )

        try await run.run("BACK-1", in: world)

        // One Attempt, two Rounds' worth of worker dispatches, and no "reset" anywhere in the log: a
        // Round (same Route, same Worktree) is never a new Attempt.
        #expect(!log.all.contains("reset"))
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(try world.card("BACK-1").state == .done)
    }
}
