import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// routing/exclude-tried-routes-on-retry (P7.7): a hard failure excludes its Route so the next dispatch
// lands on a fallback; Crashed-Unknown never excludes, so the same Route is tried again; a question
// resumes on a new Attempt without excluding anything; an Override pinned in triage that differs from
// the pin the Card's current epoch ran under resets that epoch once, never twice under the same pin,
// and never when the epoch has no Attempt yet. Split out of CardRoutingTests.swift, whose suite this
// extends, to keep that file under the length limit. Rehearsal-assertable against the in-memory board.

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private let claudeOpus = route("claude", "opus", "high")
private let codexMedium = route("codex", "gpt-5.4", "medium")

/// `insertFixtureCard` writes a Card of Kind `card` in repository `main`; this table routes it.
private let table = RoutingTable(entries: [
    RoutingEntry(kind: Kind("card")!, route: claudeOpus, fallbacks: [codexMedium])
])

private func resolver(probe: @escaping RouteResolver.ProbeEligibility = { _ in .offered }) -> RouteResolver {
    RouteResolver(table: table, probeEligibility: probe)
}

/// Claims the Act-scoped lease for `runID`, so the Journal writes under it revalidate.
private func claimActLease(_ journal: JournalStore, runID: RunID) throws {
    let claim = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: outboxEpoch)
    guard case .claimed = claim else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
}

extension CardRoutingTests {
    @Test("Hard failure then retry: the second Attempt lands on the fallback, excluding the first")
    func hardFailureThenRetryLandsOnFallback() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let first = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt1, let resolved1) = first else {
            Issue.record("expected an Attempt, got \(first)")
            return
        }
        #expect(attempt1.route == claudeOpus)
        #expect(resolved1.source == "entry")

        _ = try journal.endAttempt(
            attemptID: attempt1.id, ending: .hardFailure(.exitStatus(2)), runID: runID, act: .build
        )

        let second = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt2, let resolved2) = second else {
            Issue.record("expected an Attempt, got \(second)")
            return
        }
        #expect(attempt2.route == codexMedium)
        #expect(resolved2.skipped == [SkippedCandidate(route: claudeOpus, reason: .attemptHistory)])
        #expect(resolved2.source == "fallback:1")
        #expect(attempt2.routeSource == "fallback:1")

        let events = try journal.events(ofType: .routeRetried)
        #expect(events.count == 1)
        guard case .routeRetried(_, _, let attemptID, let route, let differentRoute) = events[0].event else {
            Issue.record("expected routeRetried")
            return
        }
        #expect(attemptID == attempt2.id)
        #expect(route == codexMedium)
        #expect(differentRoute == true)
    }

    @Test("Crashed-Unknown then retry: the Route is not excluded, so the second Attempt lands on it again")
    func crashedUnknownThenRetryLandsOnSameRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let first = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt1, _) = first else {
            Issue.record("expected an Attempt, got \(first)")
            return
        }
        _ = try journal.endAttempt(
            attemptID: attempt1.id, ending: .crashedUnknown(.signaled(9)), runID: runID, act: .build
        )

        let second = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt2, let resolved2) = second else {
            Issue.record("expected an Attempt, got \(second)")
            return
        }
        #expect(attempt2.route == claudeOpus)
        #expect(resolved2.skipped.isEmpty)
        #expect(resolved2.source == "entry")

        let events = try journal.events(ofType: .routeRetried)
        #expect(events.count == 1)
        guard case .routeRetried(_, _, let attemptID, let route, let differentRoute) = events[0].event else {
            Issue.record("expected routeRetried")
            return
        }
        #expect(attemptID == attempt2.id)
        #expect(route == claudeOpus)
        #expect(differentRoute == false)
    }

    @Test("A question then resumption: a new Attempt is recorded, nothing excluded")
    func questionThenResumptionRecordsANewAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let first = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt1, _) = first else {
            Issue.record("expected an Attempt, got \(first)")
            return
        }
        _ = try journal.endAttempt(attemptID: attempt1.id, ending: .question, runID: runID, act: .build)

        let second = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt2, _) = second else {
            Issue.record("expected an Attempt, got \(second)")
            return
        }
        #expect(attempt2.route == claudeOpus)
        #expect(attempt2.id != attempt1.id)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
    }

    @Test("An Override pinned in triage resets the budget epoch once, not again under the same pin")
    func overridePinnedInTriageResetsTheEpochOnce() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let first = try await routing.route(card: try journal.card(id: cardID), repoRole: .backend, override: .none)
        guard case .attempt(let attempt1, _) = first else {
            Issue.record("expected an Attempt, got \(first)")
            return
        }
        #expect(attempt1.route == claudeOpus)
        _ = try journal.endAttempt(
            attemptID: attempt1.id, ending: .hardFailure(.exitStatus(2)), runID: runID, act: .build
        )
        #expect(try journal.card(id: cardID).budgetEpoch == 0)

        let second = try await routing.route(
            card: try journal.card(id: cardID), repoRole: .backend, override: Override(cli: "claude")
        )
        guard case .attempt(let attempt2, let resolved2) = second else {
            Issue.record("expected an Attempt, got \(second)")
            return
        }
        #expect(try journal.card(id: cardID).budgetEpoch == 1)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
        #expect(attempt2.route == claudeOpus)
        #expect(attempt2.overridePin == "claude/-/-")
        #expect(resolved2.source == "override")
        #expect(try journal.events(ofType: .budgetEpochReset).count == 1)

        _ = try journal.endAttempt(attemptID: attempt2.id, ending: .question, runID: runID, act: .build)

        let third = try await routing.route(
            card: try journal.card(id: cardID), repoRole: .backend, override: Override(cli: "claude")
        )
        guard case .attempt = third else {
            Issue.record("expected an Attempt, got \(third)")
            return
        }
        #expect(try journal.card(id: cardID).budgetEpoch == 1)
        #expect(try journal.events(ofType: .budgetEpochReset).count == 1)
    }

    @Test("An Override present from the first dispatch causes no reset: the epoch has no Attempt yet")
    func overrideOnFirstDispatchCausesNoReset() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try claimActLease(journal, runID: runID)
        let routing = CardRouting(resolver: resolver(), journal: journal, runID: runID, act: .build)

        let outcome = try await routing.route(
            card: try journal.card(id: cardID), repoRole: .backend, override: Override(cli: "claude")
        )

        guard case .attempt(let attempt, let resolved) = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        #expect(attempt.route == claudeOpus)
        #expect(resolved.source == "override")
        #expect(try journal.card(id: cardID).budgetEpoch == 0)
        #expect(try journal.events(ofType: .budgetEpochReset).isEmpty)
    }
}
