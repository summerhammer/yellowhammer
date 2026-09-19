import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// loop-state/record-failure-cause-recurrence (roadmap P8.8): a failure cause met again on a later Night
// of the same Project promotes the Card to Triage instead of retrying it on a further Route, even with
// Attempt budget left; a first occurrence never does. Nothing here asserts model quality: the fixtures
// fail by construction, and the wiring and the count are all that is checked.

private let recurrenceSecondNight = NightStart(rawValue: "2026-09-16")!

private func twoRouteResolver() -> RouteResolver {
    cardRunResolver(table: RoutingTable(entries: [
        RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
    ]))
}

private func makeRun(worker: RehearsalResultFixture, attemptsPerCard: Int, log: CallLog = CallLog()) -> CardRun {
    CardRun(
        resolver: twoRouteResolver(), dispatch: LoggingDispatch(log: log, script: [.worker: worker]),
        check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2,
        attemptsPerCard: attemptsPerCard, resetting: RecordingAttemptResetting()
    )
}

extension CardRunWorld {
    /// The same Project's Journal on a later Night: the earlier Act's Lease released, a new run holding
    /// a new one, a new Night opened, and the Blocked Card made ready again with a fresh budget epoch —
    /// what re-readying a Card Blocked by a failure does.
    func onNextNight(_ nightStart: NightStart, reReadying issueID: String) throws -> CardRunWorld {
        _ = try journal.releaseActLease(runID: runID)
        let nextRunID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: nextRunID, mode: .rehearsal) else {
            throw JournalError.actLeaseLost(runID: nextRunID, holder: nil)
        }
        let night = try journal.openNight(nightStart: nightStart, mode: .rehearsal, act: .build, runID: nextRunID).night
        let cardID = try #require(cardIDs[issueID])
        try journal.transitionCard(cardID: cardID, to: .todo, runID: nextRunID, act: .build, nightID: night.id)
        try journal.resetBudgetEpoch(
            cardID: cardID, reason: "re-readied", runID: nextRunID, act: .build, nightID: night.id
        )
        let actContext = ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: nextRunID, journal: journal, night: night,
            outbox: nil, board: nil
        )
        let next = BuildActContext(
            act: actContext, feature: context.feature, cycleID: context.cycleID,
            reconciliation: WorktreeReconciliation(), deltaRead: nil
        )
        return CardRunWorld(journal: journal, runID: nextRunID, cardIDs: cardIDs, context: next, boards: nil)
    }
}

@Suite("Card run, Failure-Cause Recurrence (P8.8)")
struct CardRunRecurrenceTests {
    @Test("A first occurrence is counted but never promotes: the Card Blocks on its spent Attempt budget")
    func firstOccurrenceDoesNotPromote() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), withBoard: false)

        try await makeRun(worker: .workerFailed, attemptsPerCard: 2).run("BACK-1", in: world)

        // Two Attempts failed of the same cause within one Night: one occurrence, not a recurrence.
        let cardID = try #require(world.cardIDs["BACK-1"])
        let causes = try world.journal.failureCauses(cardID: cardID)
        #expect(causes.map(\.recurrenceCount) == [1])
        #expect(try world.attempts("BACK-1").count == 2)
        let steps = try cardRunLog(world.journal)
        #expect(steps.contains(CardRunStep.attemptsExhausted.rawValue))
        #expect(!steps.contains(CardRunStep.promotedToTriage.rawValue))
        #expect(try world.card("BACK-1").state == .blocked)
    }

    @Test("The same cause on a later Night promotes to Triage after one Attempt, with budget and a Route left")
    func recurrenceOnALaterNightPromotes() async throws {
        let fixture = try OutboxJournalFixture()
        let first = try await makeCardRunWorld(journal: try fixture.open(), withBoard: false)
        try await makeRun(worker: .workerFailed, attemptsPerCard: 1).run("BACK-1", in: first)
        let attemptsOnFirstNight = try first.attempts("BACK-1").count

        let second = try first.onNextNight(recurrenceSecondNight, reReadying: "BACK-1")
        let log = CallLog()
        try await makeRun(worker: .workerFailed, attemptsPerCard: 3, log: log).run("BACK-1", in: second)

        // One Attempt only: the fallback Route was never tried, although two Attempts remained.
        #expect(log.all == ["dispatch architect", "dispatch worker"])
        #expect(try second.attempts("BACK-1").count == attemptsOnFirstNight + 1)
        let card = try second.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.hardFailure.rawValue)

        let cardID = try #require(second.cardIDs["BACK-1"])
        #expect(try second.journal.failureCauses(cardID: cardID).map(\.recurrenceCount) == [2])

        let secondNightSteps = try second.journal.events().filter { $0.runID == second.runID }.compactMap {
            if case .cardRunStep(_, _, let step, let detail) = $0.event { (step, detail) } else { nil }
        }
        let promotion = try #require(secondNightSteps.first { $0.0 == .promotedToTriage })
        #expect(promotion.1?.contains("recurred across 2 Nights") == true)
        #expect(!secondNightSteps.contains { $0.0 == .attemptsExhausted })
    }

    @Test("A different cause on a later Night is a first occurrence of its own: the Card retries as usual")
    func aDifferentCauseDoesNotPromote() async throws {
        let fixture = try OutboxJournalFixture()
        let first = try await makeCardRunWorld(journal: try fixture.open(), withBoard: false)
        try await makeRun(worker: .workerFailed, attemptsPerCard: 1).run("BACK-1", in: first)

        let second = try first.onNextNight(recurrenceSecondNight, reReadying: "BACK-1")
        let log = CallLog()
        try await makeRun(worker: .workerMalformed, attemptsPerCard: 2, log: log).run("BACK-1", in: second)

        #expect(log.all.filter { $0 == "dispatch worker" }.count == 2)
        let cardID = try #require(second.cardIDs["BACK-1"])
        #expect(try second.journal.failureCauses(cardID: cardID).map(\.recurrenceCount) == [1, 1])
        #expect(!(try cardRunLog(second.journal)).contains(CardRunStep.promotedToTriage.rawValue))
    }
}
