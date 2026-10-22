import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

@Suite("CLI usage limit policy")
struct UsageLimitPolicyTests {
    private let claude = Route(cli: "claude", model: "opus", effort: "high")!
    private let codex = Route(cli: "codex", model: "gpt-6.1-sol", effort: "medium")!

    @Test("Refusal consumes no Attempt, excludes no Route and has no failure recurrence cause")
    func accounting() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
        let cardID = try insertFixtureCard(journal, issueID: "limited")
        let attempt = try journal.recordAttempt(cardID: cardID, route: claude, runID: runID)
        _ = try journal.endAttempt(attemptID: attempt.id, ending: .usageLimited(), runID: runID)
        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.openAttempt == nil)
        #expect(history.consumption(inEpoch: 0).consumed == 0)
        #expect(history.consumption(inEpoch: 0).notConsumed == 1)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
        #expect(FailureCause(ending: .usageLimited()) == nil)
        #expect(try journal.events(ofType: .failureCauseRecorded).isEmpty)
    }

    @Test("Backoff survives reopen, expires deterministically and retains the vendor reset hint")
    func persistenceAndExpiry() throws {
        let fixture = try OutboxJournalFixture()
        let now = Date()
        let hint = "try again at 2:55 PM"
        do {
            let journal = try fixture.open()
            try journal.recordUsageLimit(route: claude, resetHint: hint, runID: RunID(),
                                         act: .build, nightID: nil, now: now)
        }
        let reopened = try fixture.open()
        #expect(try reopened.backingOffCLIs(asOf: now.addingTimeInterval(1739)) == ["claude"])
        #expect(try reopened.backingOffCLIs(asOf: now.addingTimeInterval(1740)).isEmpty)
        let event = try #require(reopened.events(ofType: .routeUsageLimited).first)
        guard case .routeUsageLimited(let route, let cli, _, let storedHint) = event.event else {
            Issue.record("expected a usage refusal event")
            return
        }
        #expect(route == claude.description)
        #expect(cli == "claude")
        #expect(storedHint == hint)
    }

    @Test("A zoned reset hint sets the backoff to the reset instant; a firing just before it is not skipped")
    func zonedHint() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let refusedAt = try #require(ISO8601DateFormatter().date(from: "2026-10-21T21:52:28Z"))
        let resetAt = try #require(ISO8601DateFormatter().date(from: "2026-10-21T22:50:00Z"))
        try journal.recordUsageLimit(
            route: claude, resetHint: "You've hit your session limit · resets 1:50am (Europe/Kiev)",
            runID: RunID(), act: .build, nightID: nil, now: refusedAt)
        let event = try #require(journal.events(ofType: .routeUsageLimited).first)
        guard case .routeUsageLimited(_, _, let until, _) = event.event else {
            Issue.record("expected a usage refusal event")
            return
        }
        #expect(until == resetAt)
        #expect(try journal.backingOffCLIs(asOf: resetAt.addingTimeInterval(-61)) == ["claude"])
        #expect(try journal.backingOffCLIs(asOf: resetAt.addingTimeInterval(-11)).isEmpty)
    }

    @Test("Hints without a zone, unparseable hints and out-of-bounds resets fall back to bounded delays")
    func hintBounds() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-21T21:52:28Z"))
        let thirty = now.addingTimeInterval(30 * 60)
        #expect(UsageLimitReset.until(resetHint: nil, now: now) == thirty)
        #expect(UsageLimitReset.until(resetHint: "try again at 2:55 PM", now: now) == thirty)
        #expect(UsageLimitReset.until(resetHint: "resets 1:50am (Not/AZone)", now: now) == thirty)
        #expect(UsageLimitReset.until(resetHint: "resets 13:50am (Europe/Kiev)", now: now) == thirty)
        // 12am Kiev is 21:00Z; the next one is 21:00Z tomorrow, beyond the ceiling.
        #expect(UsageLimitReset.until(resetHint: "resets 12am (Europe/Kiev)", now: now)
            == now.addingTimeInterval(UsageLimitReset.maximumDelay))
        // A reset one minute away is held to the minimum.
        let nearly = try #require(ISO8601DateFormatter().date(from: "2026-10-21T22:49:00Z"))
        #expect(UsageLimitReset.until(resetHint: "resets 1:50am (Europe/Kiev)", now: nearly)
            == nearly.addingTimeInterval(UsageLimitReset.minimumDelay))
        // pm and minute-less forms, and the next occurrence rolling over to tomorrow.
        #expect(UsageLimitReset.resetsAt(from: "resets 12pm (UTC)", now: now)
            == ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z"))
        #expect(UsageLimitReset.resetsAt(from: "resets 1:50am (Europe/Kiev)", now: now.addingTimeInterval(3600))
            == ISO8601DateFormatter().date(from: "2026-10-22T22:50:00Z"))
    }

    @Test("Backoff skips every model on a CLI, falls back across CLIs, and recovers after expiry")
    func routingAndRecovery() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
        let cardID = try insertFixtureCard(journal, issueID: "limited")
        let card = try journal.card(id: cardID)
        let resolver = RouteResolver(table: RoutingTable(entries: [
            RoutingEntry(kind: Kind("card")!, route: claude, fallbacks: [
                Route(cli: "claude", model: "sonnet", effort: "high")!, codex
            ])
        ]), probeEligibility: { _ in .offered })
        let now = Date()
        try journal.recordUsageLimit(route: claude, resetHint: nil, runID: runID, act: .build, nightID: nil)
        let request = RouteRequest(kind: Kind("card")!, repoRole: nil)
        guard case .resolved(let fallback) = try resolver.resolve(request, backingOffCLIs: journal.backingOffCLIs())
        else { Issue.record("expected fallback"); return }
        #expect(fallback.route == codex)
        try journal.recordUsageLimit(route: codex, resetHint: nil, runID: runID, act: .build, nightID: nil)
        let routing = CardRouting(resolver: resolver, journal: journal, runID: runID, act: .build)
        guard case .backingOff = try await routing.route(card: card, repoRole: nil, override: nil) else {
            Issue.record("temporary exhaustion must defer")
            return
        }
        #expect(try journal.card(id: cardID).state == .todo)
        #expect(try journal.attemptHistory(cardID: cardID).attempts.isEmpty)
        #expect(try journal.events(ofType: .routeExhausted).isEmpty)
        guard case .resolved(let recovered) = try resolver.resolve(request,
            backingOffCLIs: journal.backingOffCLIs(asOf: now.addingTimeInterval(1801))) else {
            Issue.record("expected expiry recovery")
            return
        }
        #expect(recovered.route == claude)
    }

    @Test("Only an explicitly recorded refusal before the worker is removed from Verification writers")
    func writerAccounting() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
        let cardID = try insertFixtureCard(journal, issueID: "limited")
        let cycleID = try journal.card(id: cardID).cycleID
        let first = try journal.recordAttempt(cardID: cardID, route: claude, runID: runID)
        _ = try journal.endAttempt(attemptID: first.id,
            ending: .usageLimited(beforeWorker: true), runID: runID)
        #expect(try journal.attemptRoutes(cycleID: cycleID).isEmpty)
        let second = try journal.recordAttempt(cardID: cardID, route: claude, runID: runID)
        _ = try journal.endAttempt(attemptID: second.id, ending: .usageLimited(), runID: runID)
        #expect(try journal.attemptRoutes(cycleID: cycleID) == [claude])
    }

    @Test("Capability exclusion takes precedence over temporary CLI backoff")
    func permanentExhaustion() throws {
        let resolver = RouteResolver(table: RoutingTable(entries: [
            RoutingEntry(kind: Kind("card")!, route: claude)
        ]), probeEligibility: { _ in .offered })
        let request = RouteRequest(kind: Kind("card")!, repoRole: nil, excludedRoutes: [claude])
        guard case .exhausted(let reason) = try resolver.resolve(request, backingOffCLIs: ["claude"]) else {
            Issue.record("expected permanent exhaustion")
            return
        }
        #expect(reason.skipped.map(\.reason) == [.attemptHistory])
    }
}

private struct UsageRefusingDispatch: AgentDispatch {
    let refusedPass: RunPass
    let log: CallLog

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        if request.pass == refusedPass {
            log.add("usage refusal \(request.route.cli)")
            return AgentDispatchReport(outcome: .usageLimited(resetHint: "resets 2:20pm (Europe/Kiev)"))
        }
        return try await LoggingDispatch(log: log, script: .empty).dispatch(request)
    }
}

extension UsageLimitPolicyTests {
    @Test("A Card usage refusal stops ready without spending its Attempt, and the next firing falls back",
          arguments: [RunPass.architect, .worker, .reviewer])
    func cardRunDefersAndFallsBack(pass: RunPass) async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: fixture.open())
        let log = CallLog()
        let resolver = cardRunResolver(table: RoutingTable(entries: [
            RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
        ]))
        let run = CardRun(resolver: resolver, dispatch: UsageRefusingDispatch(refusedPass: pass, log: log),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2,
            attemptsPerWorkCard: 3, passTimeoutMinutes: 60, resetting: RecordingAttemptResetting())
        try await run.run("BACK-1", in: world)
        let cardID = try #require(world.cardIDs["BACK-1"])
        #expect(try world.card("BACK-1").state == .todo)
        #expect(try world.journal.attemptHistory(cardID: cardID).consumption(inEpoch: 0).consumed == 0)
        #expect(try world.journal.excludedRoutes(cardID: cardID).isEmpty)
        #expect(try world.journal.events(ofType: .failureCauseRecorded).isEmpty)
        #expect(try world.attempts("BACK-1").count == 1)
        let proximity = try NightSummary.boundProximity(night: world.context.act.night,
            events: world.journal.events(), journal: world.journal, bounds: .init())
        #expect(proximity.first { $0.name == "attempts_per_work_card" }?.observed == 0)
        let writers = try world.journal.attemptRoutes(cycleID: world.context.cycleID)
        #expect(writers.contains(cardRunOpus) == (pass != .architect))
        try await run.run("BACK-1", in: world)
        #expect(try world.attempts("BACK-1").map(\.route) == [cardRunOpus, cardRunFallback])
        #expect(try world.card("BACK-1").state == .todo)
        #expect(try world.journal.attemptHistory(cardID: cardID).consumption(inEpoch: 0).consumed == 0)
    }
}
