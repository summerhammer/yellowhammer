import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

// The Operator's abort (spec: app/stop-the-engine-for-a-project, P18.10): the running Card run honours
// the request recorded in the Journal, and the Expired Lease Sweep honours it when the run died first.

@Suite("Card run: the Operator's abort")
struct CardRunOperatorAbortTests {
    private func makeRun(log: CallLog, dispatch: any AgentDispatch) -> CardRun {
        CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting(log: log), operatorAbortPoll: .milliseconds(20)
        )
    }

    @Test("A request recorded mid-pass ends the Attempt aborted and Blocks the Card operator abort")
    func requestMidPassAbortsTheAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let log = CallLog()
        let dispatch = AbortingOnCancelDispatch(log: log) { pass in
            guard pass == .worker else { return }
            let attempt = try #require(try journal.attemptHistory(cardID: cardID).openAttempt)
            _ = try journal.requestOperatorAbort(attemptID: attempt.id)
            try await waitForCancellation()
        }

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts.first?.result == AttemptOutcome.aborted.rawValue)
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.operatorAbort.rawValue)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
        #expect(try journal.attemptHistory(cardID: cardID).consumption(inEpoch: 0).consumed == 0)
        let steps = try cardRunSteps(journal, cardID: cardID)
        let aborted = try #require(steps.first { $0.step == .operatorAborted })
        #expect(aborted.detail == "attempt \(try #require(attempts.first).id)")
        #expect(!steps.contains { $0.step == .attemptReset || $0.step == .attemptsExhausted })
        #expect(steps.contains { $0.step == .leaseReleased })
        #expect(try journal.currentCardLease(cardID: cardID) == nil)
        #expect(log.all == ["dispatch architect", "dispatch worker"])

        // Night Summary: the abort has its own disposition line, and no failure cause was recorded.
        let lines = try NightSummary.dispositionLines(night: world.context.act.night, journal: journal)
        let attemptID = try #require(attempts.first).id
        #expect(lines.contains(
            "`BACK-1` was stopped by the Operator: Attempt \(attemptID) aborted, consuming no Attempt and " +
                "excluding no Route. It stays Blocked (`operator abort`) until re-ready."
        ))
        #expect(!lines.contains { $0.contains("occurrence") || $0.contains("recurrence") })
    }

    @Test("Outer cancellation beats a recorded request: nothing is written aborted, the Lease is left to expire")
    func outerCancellationBeatsTheRequest() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let log = CallLog()
        let beatFails = Mutex(false)
        // The heartbeat fails and the request lands in the same pass; the heartbeat's failure cancels the
        // run from outside, and that wins whenever the poller has not already ended the Attempt.
        let dispatch = AbortingOnCancelDispatch(log: log) { pass in
            guard pass == .worker else { return }
            beatFails.withLock { $0 = true }
            try await waitForCancellation()
        }
        let run = makeRun(log: log, dispatch: dispatch)

        await #expect(throws: TransientBeatFailure.self) {
            try await withLeaseHeartbeat(
                every: .milliseconds(5),
                beat: { if beatFails.withLock({ $0 }) { throw TransientBeatFailure() } },
                body: { try await run.run("BACK-1", in: world) }
            )
        }

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts.first?.result != AttemptOutcome.aborted.rawValue)
        #expect(try world.card("BACK-1").state == .inProgress)
        let steps = try cardRunSteps(journal, cardID: cardID)
        #expect(steps.last?.step == .leaseLeftToExpire)
        #expect(!steps.contains { $0.step == .operatorAborted })
    }

    @Test("A request recorded for another Card's Attempt does not stop this run")
    func requestForAnotherAttemptIsIgnored() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(
            journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend")]
        )
        let otherID = try #require(world.cardIDs["BACK-2"])
        let otherRun = RunID()
        let route = try #require(Route(cli: "claude", model: "opus", effort: "high"))
        let other = try journal.recordAttempt(cardID: otherID, route: route, runID: world.runID)
        _ = otherRun
        _ = try journal.requestOperatorAbort(attemptID: other.id)
        let log = CallLog()
        let dispatch = AbortingOnCancelDispatch(log: log) { pass in
            // Long enough for several polls, which must all find no request for this Attempt.
            if pass == .worker { try? await Task.sleep(for: .milliseconds(150)) }
        }

        try await makeRun(log: log, dispatch: dispatch).run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.first?.result != AttemptOutcome.aborted.rawValue)
        #expect(try world.card("BACK-1").blockReason != BlockReason.operatorAbort.rawValue)
        #expect(log.all.contains("dispatch worker"))
    }

    @Test("The Night Summary words a reclaim of an aborted Attempt as stopped by the Operator")
    func reclaimedAbortLineInNightSummary() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let context = world.context.act
        try journal.append(
            .cardReclaimed(
                cardID: cardID, issueID: "BACK-1", previousRunID: RunID(), attemptID: 7,
                outcome: AttemptEnding.aborted.consumedHow, routeExcluded: false
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )

        let lines = try NightSummary.crashesAndReclaimsLines(night: context.night, journal: journal)

        let line = try #require(lines.first)
        #expect(line.hasPrefix("Card `BACK-1` was stopped by the Operator. Its Lease, held by run "))
        #expect(line.contains("the Card is reclaimable, and no partial state was written as if it were complete."))
        #expect(line.contains("Attempt `7` was classified"))
    }
}

@Suite("ExpiredLeaseSweep: the Operator's abort request")
struct ExpiredLeaseSweepOperatorAbortTests {
    @Test("A dead run's open Attempt with a request and no result file is aborted; the Card Blocks operator abort")
    func requestedAbortIsHonouredByTheSweep() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let worktree = try makeReclaimWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: worktree)
        try appendPassStep(journal, card: card, step: .worker, detail: "completed", runID: deadRun)
        #expect(try journal.requestOperatorAbort(attemptID: card.attemptID))

        let night = try journal.openNight(
            nightStart: buildActNightStart, mode: .rehearsal, act: .build, runID: runID
        ).night
        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: card.issueID, description: nil)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let outbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .build, nightID: night.id)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: night.id, clock: { reclaimEpoch },
            projection: projection
        )

        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let attempt = try #require(try journal.attemptHistory(cardID: card.cardID).attempts.first)
        #expect(attempt.result == AttemptOutcome.aborted.rawValue)
        #expect(try journal.excludedRoutes(cardID: card.cardID).isEmpty)
        let reclaimed = try journal.card(id: card.cardID)
        #expect(reclaimed.state == .blocked)
        #expect(reclaimed.blockReason == BlockReason.operatorAbort.rawValue)
        // The board, not only the Journal: the issue is Blocked and carries the `operator abort` label.
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: card.issueID)))
        #expect(issue.workflowState == scope.states[.blocked])
        #expect(issue.labels.contains(try #require(boards.ids["operator abort"])))

        let comment = try #require(await boards.writing.comments.first { $0.issue.rawValue == card.issueID })
        #expect(comment.body.hasPrefix(
            "Yellowhammer reclaimed this Card: the Card is reclaimable, and no partial state was written " +
                "as if it were complete. "
        ))
        #expect(comment.body.contains("was stopped by the Operator before it recorded the abort"))
        #expect(comment.body.contains("The Card is Blocked (operator abort) until re-ready."))
        #expect(!comment.body.contains("never released it"))
    }
}
