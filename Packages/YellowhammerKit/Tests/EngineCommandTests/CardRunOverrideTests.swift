import Domain
@testable import Engine
import Foundation
import Journal
import Synchronization
import Testing

// routing/resolve-a-route-for-a-card (roadmap P22.7), end to end through the Card run: the Card override is
// the `Card override:` line the Operator wrote in the Card's description, held in the Journal by the import
// before the run. A valid one is selected before Work Kind and Repo Role; a Route that fails its Route
// Pre-flight, or whose CLI failed its Probe, is a Readiness Check failure — nothing dispatched, no Attempt,
// and the reason posted on the Card; emptying the line returns the Card to its Routing Entry.

/// A pre-flight that fails every Route, counting what it was asked.
private final class RejectingPreflight: RoutePreflighting {
    let asked = Mutex<[Route]>([])

    func preflight(_ route: Route, runID: RunID) async throws -> RoutePreflightVerdict {
        asked.withLock { $0.append(route) }
        return .failed(reason: "`\(route.cli)` rejected model `\(route.model)`")
    }
}

/// Records what the Operator saved in `issueID`'s description, as the import does before a run.
private func saving(_ lines: [String], on issueID: String, in world: CardRunWorld) throws {
    try world.journal.recordCardOverrideLines(cardID: try #require(world.cardIDs[issueID]), lines: lines)
}

private func run(
    _ world: CardRunWorld, resolver: RouteResolver = cardRunResolver(), preflighting: (any RoutePreflighting)? = nil,
    dispatch: RehearsalDispatch = RehearsalDispatch()
) async throws {
    let log = CallLog()
    let run = CardRun(
        resolver: resolver, dispatch: dispatch, check: RecordingCheck(log: log),
        checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3, passTimeoutMinutes: 60,
        resetting: RecordingAttemptResetting(), preflighting: preflighting
    )
    try await run.run("BACK-1", in: world)
}

@Suite("Card run: the Card override field")
struct CardRunOverrideTests {
    @Test("A Route that fails its pre-flight dispatches nothing, records no Attempt, and says why on the Card")
    func failedPreflightIsReportedOnTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try saving(["Card override: agy/opus/max"], on: "BACK-1", in: world)
        let preflight = RejectingPreflight()
        let rehearsal = RehearsalDispatch()

        try await run(world, preflighting: preflight, dispatch: rehearsal)

        #expect(preflight.asked.withLock { $0 } == [Route(cli: "agy", model: "opus", effort: "max")!])
        #expect(rehearsal.answered.isEmpty)
        #expect(try world.attempts("BACK-1").isEmpty)
        #expect(try world.card("BACK-1").state == .todo)
        let comments = await try #require(world.boards).writing.comments
        #expect(comments.count == 1)
        #expect(comments.first?.issue == BoardObjectID(rawValue: "BACK-1"))
        #expect(comments.first?.body.contains("`agy` rejected model `opus`") == true)
        #expect(comments.first?.body.contains("consumed no Attempt") == true)
        #expect(comments.first?.body.contains("`Card override:` line") == true)
    }

    @Test("A valid field beats the Routing Entry for the Card's Kind, and the Attempt records the pin")
    func fieldIsSelectedBeforeKindAndRole() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try saving(["Card override: \(cardRunFallback)"], on: "BACK-1", in: world)

        try await run(world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.route == cardRunFallback)
        #expect(attempt.routeSource == "override")
        #expect(attempt.overridePin == cardRunFallback.description)
    }

    @Test("A table Route whose model contains a slash is matched whole, not split")
    func slashedModelIsMatchedWhole() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let slashed = Route(cli: "agy", model: "google/gemini-3-pro", effort: "high")!
        let table = RoutingTable(entries: [
            RoutingEntry(kind: Kind("card")!, route: cardRunOpus),
            RoutingEntry(kind: Kind("other")!, route: slashed)
        ])
        try saving(["Card override: AGY/Google/Gemini-3-Pro/High"], on: "BACK-1", in: world)

        try await run(world, resolver: cardRunResolver(table: table))

        #expect(try world.attempts("BACK-1").first?.route == slashed)
    }

    @Test("A field never beats a Probe failure: the Card is refused, nothing is dispatched")
    func probeFailureBeatsTheField() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try saving(["Card override: \(cardRunFallback)"], on: "BACK-1", in: world)
        let resolver = cardRunResolver(probe: { $0 == "codex" ? .excluded(reason: "probe failed") : .offered })
        let rehearsal = RehearsalDispatch()

        try await run(world, resolver: resolver, dispatch: rehearsal)

        #expect(try world.attempts("BACK-1").isEmpty)
        #expect(rehearsal.answered.isEmpty)
        let comments = await try #require(world.boards).writing.comments
        #expect(comments.first?.body.contains("Card override `codex/o3/high` pins `codex`") == true)
    }

    @Test("Fallbacks are never consulted while the field is present")
    func fallbacksAreNotConsulted() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let table = RoutingTable(entries: [
            RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
        ])
        try saving(["Card override: claude/opus/high"], on: "BACK-1", in: world)
        let resolver = cardRunResolver(
            probe: { $0 == "claude" ? .excluded(reason: "probe failed") : .offered }, table: table
        )

        try await run(world, resolver: resolver)

        // The primary is the pinned Route and its CLI failed its Probe: the fallback is not tried.
        #expect(try world.attempts("BACK-1").isEmpty)
    }

    @Test("Emptying the field returns the Card to normal routing on the next Act")
    func clearingTheFieldReturnsToDefaults() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try saving(["Card override: \(cardRunFallback)"], on: "BACK-1", in: world)
        try saving(["Card override:"], on: "BACK-1", in: world)

        try await run(world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.route == cardRunOpus)
        #expect(attempt.routeSource == "entry")
        #expect(attempt.overridePin == nil)
    }

    @Test("A malformed field is never read as a silent fallback to normal routing")
    func malformedFieldNeverFallsBack() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        try saving(["Card override:  \(cardRunFallback)"], on: "BACK-1", in: world)
        let rehearsal = RehearsalDispatch()

        await #expect(throws: CardRunError.self) { try await run(world, dispatch: rehearsal) }

        #expect(try world.attempts("BACK-1").isEmpty)
        #expect(rehearsal.answered.isEmpty)
    }
}
