import Domain
@testable import Engine
import Foundation
import Journal
import Testing

@Suite("Usage-limited Attempt hand-over (OQ179)")
struct UsageLimitedHandoverTests {
    @Test("SUM-74: a later Act's instruction carries the refused Attempt's ref and all recorded Rounds",
          arguments: [false, true])
    func laterActCarriesRefAndRounds(sameRoute: Bool) async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: fixture.open(), withBoard: false)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let prior = try seedPreservedAttempt(world, ending: .usageLimited())
        // Model-authored review and Check results are recorded inputs here, never tested as judgments.
        let source = try #require(world.attempts("BACK-1").first)
        #expect(source.rounds.count == 2)
        _ = try world.journal.releaseActLease(runID: world.runID)
        let laterRunID = RunID()
        _ = try world.journal.claimActLease(act: .build, runID: laterRunID, mode: .rehearsal)
        let laterNight = try world.journal.openNight(
            nightStart: NightStart(rawValue: "2026-10-24")!, mode: .rehearsal, act: .build, runID: laterRunID
        ).night
        let act = ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: laterRunID,
            journal: world.journal, night: laterNight
        )
        let context = BuildActContext(
            act: act, feature: world.context.feature, cycleID: world.context.cycleID,
            reconciliation: WorktreeReconciliation(), deltaRead: nil, recordedBaseMainlines: act.mainlines
        )
        let route = sameRoute ? cardRunOpus : cardRunFallback
        let dispatch = LoggingDispatch(log: CallLog())
        let run = CardRun(
            resolver: cardRunResolver(table: RoutingTable(entries: [RoutingEntry(kind: Kind("card")!, route: route)])),
            dispatch: dispatch, check: RecordingCheck(log: CallLog()), checks: ["backend": .none],
            reviewRoundsMax: 2, attemptsPerWorkCard: 3, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        let card = try world.journal.card(id: cardID)
        try await run.run(
            card: card, in: RepoLane(repository: card.repository, cards: [card]), context: context,
            readiness: CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [])
        )
        let worker = try #require(dispatch.requests.passes(.worker).first)
        let wip = try #require(worker.instruction.cardInstruction?.payloads.wip)
        #expect(worker.route == route)
        #expect(wip.commit == prior.preservedCommit)
        #expect(wip.outcome == .usageLimited)
        #expect(wip.rounds == CardRun.feedback(of: source.rounds))
        let architect = try #require(dispatch.requests.passes(.architect).first)
        #expect(architect.instruction.cardInstruction?.payloads.wip == wip)
        // The two historical Rounds are WIP context, never the new Attempt's active feedback/budget.
        #expect(worker.instruction.cardInstruction?.payloads.roundFeedback.isEmpty == true)
        try expectRenderedHandover(worker, prior: prior)
    }

    private func expectRenderedHandover(_ worker: AgentDispatchRequest, prior: AttemptRecord) throws {
        let rendered = worker.instruction.render()
        #expect(rendered.contains(try #require(prior.preservedRef)))
        #expect(rendered.contains("Prior Attempt outcome (not known-good): usage limited"))
        #expect(rendered.contains(
            "Round 1 (review): verdict changes_requested; requested changes: Fix SUM-74 edge case"
        ))
        #expect(rendered.contains("judged commit: e5a725d"))
        #expect(rendered.contains("Round 2 (check): verdict failed; requested changes: Fix fixture compilation"))
        #expect(rendered.contains("fresh round budget"))
        #expect(rendered.contains("merge or cherry-pick"))
        #expect(rendered == worker.instruction.render())
    }

    @Test("Repeated architect refusals pass the incoming hand-over on unchanged",
          arguments: [AttemptEnding.usageLimited(), .question])
    func emptyRefusalsPassOnContext(ending: AttemptEnding) async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: fixture.open(), withBoard: false)
        _ = try seedPreservedAttempt(world, ending: ending)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let incoming = try #require(try CardRun.resumedWIPContext(cardID: cardID, journal: world.journal))
        for route in [cardRunFallback, cardRunOpus] {
            let refused = try world.journal.recordAttempt(cardID: cardID, route: route, runID: world.runID)
            _ = try world.journal.endAttempt(
                attemptID: refused.id, ending: .usageLimited(beforeWorker: true), runID: world.runID
            )
            #expect(try CardRun.resumedWIPContext(cardID: cardID, journal: world.journal) == incoming)
        }
    }

    @Test("Other latest endings never resurrect old preserved work",
          arguments: [AttemptEnding.success, .hardFailure(.exitStatus(1)), .roundsExhausted(rounds: 2),
                      .crashedUnknown(.terminated(.exited(status: 0))), .cancelled, .aborted])
    func unrelatedEndingsAreBoundaries(ending: AttemptEnding) async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: fixture.open(), withBoard: false)
        _ = try seedPreservedAttempt(world, ending: .usageLimited())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let unrelated = try world.journal.recordAttempt(cardID: cardID, route: cardRunFallback, runID: world.runID)
        _ = try world.journal.endAttempt(attemptID: unrelated.id, ending: ending, runID: world.runID)
        #expect(try CardRun.resumedWIPContext(cardID: cardID, journal: world.journal) == nil)
    }

    @Test("An empty refusal preserves an in-run retry's minimal hand-over, but never revives an older run",
          arguments: [true, false])
    func inRunRetryHandover(sameRun: Bool) async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: fixture.open(), withBoard: false)
        let prior = try seedPreservedAttempt(world, ending: .hardFailure(.exitStatus(1)))
        let cardID = try #require(world.cardIDs["BACK-1"])
        var runID = world.runID
        if !sameRun {
            _ = try world.journal.releaseActLease(runID: runID)
            runID = RunID()
            _ = try world.journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
        }
        let refused = try world.journal.recordAttempt(cardID: cardID, route: cardRunFallback, runID: runID)
        _ = try world.journal.endAttempt(
            attemptID: refused.id, ending: .usageLimited(beforeWorker: true), runID: runID
        )
        let incoming = sameRun ? WIPContext(
            commit: try #require(prior.preservedCommit), note: "preserved at \(try #require(prior.preservedRef))"
        ) : nil
        #expect(try CardRun.resumedWIPContext(cardID: cardID, journal: world.journal) == incoming)
        // That incoming context also survives another empty refusal in a later Card run.
        _ = try world.journal.releaseActLease(runID: runID)
        runID = RunID()
        _ = try world.journal.claimActLease(act: .build, runID: runID, mode: .rehearsal)
        let again = try world.journal.recordAttempt(cardID: cardID, route: cardRunFallback, runID: runID)
        _ = try world.journal.endAttempt(
            attemptID: again.id, ending: .usageLimited(beforeWorker: true), runID: runID
        )
        #expect(try CardRun.resumedWIPContext(cardID: cardID, journal: world.journal) == incoming)
    }

    @Test("An architect refusal with no incoming hand-over carries no WIP")
    func emptyHistory() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: fixture.open(), withBoard: false)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let refused = try world.journal.recordAttempt(cardID: cardID, route: cardRunOpus, runID: world.runID)
        _ = try world.journal.endAttempt(
            attemptID: refused.id, ending: .usageLimited(beforeWorker: true), runID: world.runID
        )
        #expect(try CardRun.resumedWIPContext(cardID: cardID, journal: world.journal) == nil)
    }

    private func seedPreservedAttempt(_ world: CardRunWorld, ending: AttemptEnding) throws -> AttemptRecord {
        let cardID = try #require(world.cardIDs["BACK-1"])
        let attempt = try world.journal.recordAttempt(cardID: cardID, route: cardRunOpus, runID: world.runID)
        try world.journal.recordRound(
            attemptID: attempt.id, lens: .review, verdict: "changes_requested",
            requestedChanges: "Fix SUM-74 edge case", judgedCommit: "e5a725d", runID: world.runID
        )
        try world.journal.recordRound(
            attemptID: attempt.id, lens: .check, verdict: "failed",
            requestedChanges: "Fix fixture compilation", judgedCommit: "follow-up-commit", runID: world.runID
        )
        _ = try world.journal.endAttempt(attemptID: attempt.id, ending: ending, runID: world.runID)
        try world.journal.recordAttemptPreservation(
            attemptID: attempt.id, ref: "refs/yellowhammer/attempts/SUM-74/\(attempt.id)", commit: "e5a725d",
            resetTo: "known-good", runID: world.runID, act: .build, nightID: world.context.act.night.id
        )
        return try #require(world.attempts("BACK-1").last)
    }
}
