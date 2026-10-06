import Domain
import Foundation
import Synchronization
import Testing

@testable import Engine
@testable import Journal

// routing/resolve-a-route-for-a-card and board-projection/check-card-readiness-at-dispatch, as amended
// by the Override Ruling (OQ126): every Card override's Route passes a Route Pre-flight before any
// Attempt is recorded on it, its verdict cached in the Journal for the rest of the Night. A fake
// pre-flight stands in for the CLI: what is asserted is the engine's bookkeeping, never a model's answer.

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private let claudeOpus = route("claude", "opus", "high")
private let table = RoutingTable(entries: [
    RoutingEntry(kind: Kind("card")!, route: claudeOpus, fallbacks: [route("codex", "gpt-5.4", "medium")])
])

/// A pre-flight that answers from a script and counts what it was asked, optionally slowly.
private final class ScriptedPreflight: RoutePreflighting {
    let asked = Mutex<[Route]>([])
    let verdict: @Sendable (Route) -> RoutePreflightVerdict
    let delay: Duration

    init(delay: Duration = .zero, verdict: @escaping @Sendable (Route) -> RoutePreflightVerdict = { _ in .passed() }) {
        self.delay = delay
        self.verdict = verdict
    }

    var calls: [Route] { asked.withLock { $0 } }

    func preflight(_ route: Route, runID: RunID) async throws -> RoutePreflightVerdict {
        asked.withLock { $0.append(route) }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return verdict(route)
    }
}

private let agyRejectsOpus: @Sendable (Route) -> RoutePreflightVerdict = { route in
    route.cli == "agy" ? .failed(reason: "`agy` rejected model `\(route.model)`") : .passed()
}

/// Claims the build Act's lease and opens a Night, so events are stamped with it.
private func openNight(_ journal: JournalStore, runID: RunID) throws -> Int64 {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try journal.openNight(
        nightStart: try #require(NightStart(rawValue: "2026-10-06")), mode: .rehearsal, act: .build, runID: runID
    )
    return try #require(opening.night.id)
}

private func routing(
    _ journal: JournalStore, runID: RunID, nightID: Int64?, preflight: RoutePreflight?,
    probe: @escaping RouteResolver.ProbeEligibility = { _ in .offered }
) -> CardRouting {
    CardRouting(
        resolver: RouteResolver(table: table, probeEligibility: probe), journal: journal, runID: runID, act: .build,
        nightID: nightID, preflight: preflight
    )
}

private func attemptCount(_ journal: JournalStore, cardID: Int64) throws -> Int {
    try journal.attemptHistory(cardID: cardID).attempts.count
}

@Suite("Route Pre-flight of a Card override")
struct CardRoutingPreflightTests {
    @Test("An off-table Override dispatches after its pre-flight passes, and the verdict is recorded for the Night")
    func passingPreflightDispatches() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let fake = ScriptedPreflight()
        let routing = routing(journal, runID: runID, nightID: nightID, preflight: RoutePreflight(fake))

        let outcome = try await routing.route(
            card: try journal.card(id: cardID), repoRole: .backend, override: Override(label: "agy/gemini-3-pro/high")
        )

        guard case .attempt(let attempt, let resolved) = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        #expect(attempt.route == route("agy", "gemini-3-pro", "high"))
        #expect(resolved.selectedBy == .override)
        #expect(fake.calls == [route("agy", "gemini-3-pro", "high")])
        let recorded = try journal.events(ofType: .routePreflightRan)
        #expect(recorded.map(\.event) == [
            .routePreflightRan(route: route("agy", "gemini-3-pro", "high"), passed: true, reason: nil)
        ])
        #expect(recorded.first?.nightID == nightID)
    }

    @Test("A failed pre-flight is a Readiness Check failure: no Attempt, the Card untouched, the reason recorded")
    func failedPreflightRefusesWithoutAnAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let routing = routing(
            journal, runID: runID, nightID: nightID,
            preflight: RoutePreflight(ScriptedPreflight(verdict: agyRejectsOpus))
        )
        let before = try journal.card(id: cardID)
        let override = Override(label: "agy/opus/max")

        let outcome = try await routing.route(card: before, repoRole: .backend, override: override)

        guard case .readinessFailure(let record, let refusal) = outcome else {
            Issue.record("expected readinessFailure, got \(outcome)")
            return
        }
        #expect(refusal == .preflightFailed(
            override, route: route("agy", "opus", "max"), reason: "`agy` rejected model `opus`"
        ))
        #expect(record == before)
        #expect(try journal.card(id: cardID) == before)
        #expect(try attemptCount(journal, cardID: cardID) == 0)
        let refused = try journal.events(ofType: .overrideRefused)
        #expect(refused.map(\.event) == [
            .overrideRefused(cardID: cardID, issueID: "issue-1", reason: refusal.description)
        ])
        #expect(refusal.description.contains("`agy` rejected model `opus`"))
    }

    @Test("Two Cards pinned to the same Route in one Night trigger one pre-flight, across Acts too")
    func oneNightOnePreflightPerRoute() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let first = try insertFixtureCard(journal, issueID: "issue-1")
        let second = try insertFixtureCard(journal, issueID: "issue-2")
        let fake = ScriptedPreflight(verdict: agyRejectsOpus)
        let pinned = Override(label: "agy/opus/max")

        _ = try await routing(journal, runID: runID, nightID: nightID, preflight: RoutePreflight(fake))
            .route(card: try journal.card(id: first), repoRole: .backend, override: pinned)
        // A later Act holds a fresh RoutePreflight: only the Journal carries the verdict over.
        let later = try await routing(journal, runID: runID, nightID: nightID, preflight: RoutePreflight(fake))
            .route(card: try journal.card(id: second), repoRole: .backend, override: pinned)

        #expect(fake.calls.count == 1)
        guard case .readinessFailure(_, .preflightFailed) = later else {
            Issue.record("expected the cached failure, got \(later)")
            return
        }
        #expect(try journal.events(ofType: .routePreflightRan).count == 1)
    }

    @Test("Cards in concurrent Repo Lanes asking about one Route at once share one pre-flight")
    func concurrentCardsShareOnePreflight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let cards = try (1...3).map { try insertFixtureCard(journal, issueID: "issue-\($0)") }
        let fake = ScriptedPreflight(delay: .milliseconds(200))
        let shared = RoutePreflight(fake)
        let pinned = Override(label: "claude/opus/high")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for cardID in cards {
                group.addTask {
                    _ = try await routing(journal, runID: runID, nightID: nightID, preflight: shared)
                        .route(card: try journal.card(id: cardID), repoRole: .backend, override: pinned)
                }
            }
            try await group.waitForAll()
        }

        #expect(fake.calls == [claudeOpus])
        #expect(try journal.events(ofType: .routePreflightRan).count == 1)
    }

    @Test("An Override whose Route's CLI failed its Probe is refused before any pre-flight")
    func probeFailureComesFirst() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let fake = ScriptedPreflight()
        let routing = routing(
            journal, runID: runID, nightID: nightID, preflight: RoutePreflight(fake),
            probe: { cli in cli == "codex" ? .excluded(reason: "never probed") : .offered }
        )

        let outcome = try await routing.route(
            card: try journal.card(id: cardID), repoRole: .backend, override: Override(label: "codex/gpt-5.4/medium")
        )

        guard case .readinessFailure(_, .probeFailed) = outcome else {
            Issue.record("expected probeFailed, got \(outcome)")
            return
        }
        #expect(fake.calls.isEmpty)
        #expect(try journal.events(ofType: .routePreflightRan).isEmpty)
    }

    @Test("A Card without an Override runs no pre-flight")
    func noOverrideNoPreflight() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let fake = ScriptedPreflight()

        let outcome = try await routing(journal, runID: runID, nightID: nightID, preflight: RoutePreflight(fake))
            .route(card: try journal.card(id: cardID), repoRole: .backend, override: nil)

        guard case .attempt = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        #expect(fake.calls.isEmpty)
    }

    @Test("A rehearsal pre-flight runs no CLI and passes, recording what answered")
    func rehearsalPreflightIsAFixture() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let nightID = try openNight(journal, runID: runID)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")

        let outcome = try await routing(
            journal, runID: runID, nightID: nightID, preflight: RoutePreflight(RehearsalRoutePreflight())
        ).route(card: try journal.card(id: cardID), repoRole: .backend, override: Override(label: "agy/opus/max"))

        guard case .attempt = outcome else {
            Issue.record("expected an Attempt, got \(outcome)")
            return
        }
        let recorded = try journal.events(ofType: .routePreflightRan).first?.event
        guard case .routePreflightRan(_, true, let answeredBy)? = recorded else {
            Issue.record("expected a passed RoutePreflightRan")
            return
        }
        #expect(answeredBy?.contains("rehearsal fixture") == true)
    }
}
