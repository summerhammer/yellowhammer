import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// Issue #173: an engine fault — an error that is neither the Card's outcome nor the engine cancelling the
// run — thrown once the Card is In Progress must not release the Card Lease. A released Lease leaves an
// In Progress Card that no Expired Lease Sweep reclaims (it has no Lease row) and no Repo Lane runs (it is
// not Todo). The Card is reclaimable, and no partial state was written as if it were complete: the Lease
// is left to expire. A fault before the Card moves still releases it (see CardRunFailureTests'
// `missingWorktreeIsAnEngineFault`): the Card is still Ready, so nothing needs reclaiming.

@Suite("Card run engine fault")
struct CardRunEngineFaultTests {
    @Test("A dispatch that throws mid-Attempt leaves the Card Lease to expire, and the next sweep reclaims the Card")
    func dispatchFaultLeavesLeaseToExpire() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: FaultingDispatch(log: log, faultOn: .worker),
            check: RecordingCheck(log: log), checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting(log: log)
        )

        await #expect(throws: EngineFault.self) {
            try await run.run("BACK-1", in: world)
        }

        #expect(log.all == ["dispatch architect", "dispatch worker"])
        #expect(try world.attempts("BACK-1").count == 1)
        #expect(try world.journal.attemptHistory(cardID: cardID).openAttempt != nil)
        #expect(try world.card("BACK-1").state == .inProgress)
        #expect(!(try cardRunLog(world.journal)).contains(CardRunStep.leaseReleased.rawValue))
        #expect(try world.journal.currentCardLease(cardID: cardID)?.runID == world.runID)

        // The terminal step (OQ92): last, after the architect pass that ran before the worker's dispatch
        // faulted, detail equal to the thrown fault's own description.
        let steps = try cardRunSteps(world.journal, cardID: cardID)
        let last = try #require(steps.last)
        #expect(last.step == .leaseLeftToExpire)
        let architectIndex = try #require(steps.firstIndex { $0.step == .architect })
        #expect(steps.count - 1 > architectIndex)
        #expect(last.detail == String(describing: EngineFault()))

        try await expectNextSweepReclaims(
            world: world, cardID: cardID, expectStoppedByEngine: true, expectReclaimedAttemptClassified: true
        )
    }

    @Test("A Worktree gone between Attempts leaves the Card Lease to expire, and the next sweep reclaims the Card")
    func worktreeMissingBetweenAttemptsLeavesLeaseToExpire() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal)
        let cardID = try #require(world.cardIDs["BACK-1"])
        let log = CallLog()
        // An empty worker result is Crashed-Unknown: the Attempt ends, and the retry's reset first looks up
        // the Worktree the worker pass took away.
        let dispatch = LoggingDispatch(log: log, script: [.worker: .workerEmpty]) { pass in
            guard pass == .worker else { return }
            try journal.write { db in try db.execute(sql: "UPDATE worktree SET repository = 'other'") }
        }
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting(log: log)
        )

        let missing = CardRunError.worktreeMissing(featureID: world.context.feature.id, repository: "backend")
        await #expect(throws: missing) {
            try await run.run("BACK-1", in: world)
        }

        #expect(try world.attempts("BACK-1").count == 1)
        #expect(try world.journal.attemptHistory(cardID: cardID).openAttempt == nil)
        #expect(try world.card("BACK-1").state == .inProgress)
        #expect(try world.journal.currentCardLease(cardID: cardID)?.runID == world.runID)

        // The terminal step (OQ92): last, after the worker pass that ended the first Attempt Crashed-
        // Unknown, detail equal to the thrown fault's own description.
        let steps = try cardRunSteps(world.journal, cardID: cardID)
        let last = try #require(steps.last)
        #expect(last.step == .leaseLeftToExpire)
        let workerIndex = try #require(steps.firstIndex { $0.step == .worker })
        #expect(steps.count - 1 > workerIndex)
        #expect(last.detail == String(describing: missing))

        try await expectNextSweepReclaims(world: world, cardID: cardID, expectStoppedByEngine: true)
    }

    /// A later build Act's Expired Lease Sweep, its clock past the Lease's TTL, reclaims the Card: it ends
    /// any open Attempt, reposts the Card to Ready (Todo), and releases the Lease again.
    ///
    /// `expectStoppedByEngine`: when true, the dead run recorded `.leaseLeftToExpire` (OQ92), so the
    /// reclaimed Attempt is still Crashed-Unknown — classification is unchanged — but its classification
    /// carries the "stopped by the engine: " prefix (only true when the sweep had an open Attempt of
    /// its own to classify — dispatch-fault leaves one open, the between-Attempts Worktree fault does
    /// not, since CardRun itself already ended that Attempt before the fault struck), and the Night
    /// Summary's own line says so either way, and avoids the word "crash".
    private func expectNextSweepReclaims(
        world: CardRunWorld, cardID: Int64, expectStoppedByEngine: Bool = false,
        expectReclaimedAttemptClassified: Bool = false
    ) async throws {
        let card = try world.card("BACK-1")
        let later = Date().addingTimeInterval(LeasePolicy.ruled.timeToLive + 60)
        let nextRunID = RunID()
        // The faulted Act is over: the next build Act holds the Project.
        try world.journal.releaseActLease(runID: world.runID)
        _ = try world.journal.claimActLease(act: .build, runID: nextRunID, mode: .rehearsal, now: later)
        let sweep = ExpiredLeaseSweep(
            journal: world.journal, runID: nextRunID, act: .build, nightID: world.context.act.night.id,
            clock: { later }
        )

        let reclaimed = try await sweep.sweep(featureID: world.context.feature.id, cycleID: card.cycleID)

        #expect(reclaimed == [cardID])
        #expect(try world.card("BACK-1").state == .todo)
        #expect(try world.journal.attemptHistory(cardID: cardID).openAttempt == nil)
        #expect(try world.journal.currentCardLease(cardID: cardID) == nil)

        if expectReclaimedAttemptClassified {
            let history = try world.journal.attemptHistory(cardID: cardID)
            let reclaimedAttempt = try #require(history.attempts.last)
            #expect(reclaimedAttempt.result == AttemptOutcome.crashedUnknown.rawValue)
            #expect(reclaimedAttempt.classification?.hasPrefix("stopped by the engine: ") == true)
        }

        guard expectStoppedByEngine else { return }
        let lines = try NightSummary.crashesAndReclaimsLines(night: world.context.act.night, journal: world.journal)
        let line = try #require(lines.first { $0.contains(card.issueID) })
        #expect(line.contains("was stopped by the engine: "))
        #expect(!line.lowercased().contains("crashed:"))
        #expect(!line.lowercased().contains("a crash"))
    }
}

private struct EngineFault: Error {}

/// A Dispatch seam that throws a plain engine error — a spawn failure, say — on one pass, and otherwise
/// answers from ``RehearsalDispatch``.
private struct FaultingDispatch: AgentDispatch {
    let log: CallLog
    let faultOn: RunPass

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.add("dispatch \(request.pass.rawValue)")
        if request.pass == faultOn { throw EngineFault() }
        return try await RehearsalDispatch().dispatch(request)
    }
}
