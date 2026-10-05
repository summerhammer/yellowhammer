import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// Issue #150: a Card run the engine cancels — the Act Lease lost, or a heartbeat that failed with the
// Leases still intact — stops at the pass the cancellation aborted. It must not conclude that pass as a
// Crashed-Unknown Attempt and retry until the Attempt budget Blocks the Card. The Card is reclaimable,
// and no partial state was written as if it were complete.

@Suite("Card run cancellation")
struct CardRunCancellationTests {
    @Test("A heartbeat failing mid-pass with the Leases intact spends no Attempt budget: the Card is reclaimable")
    func failedHeartbeatSpendsNoAttemptBudget() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let beatFails = Mutex(false)
        let log = CallLog()
        let dispatch = AbortingOnCancelDispatch(log: log) { pass in
            guard pass == .worker else { return }
            // The Act's heartbeat write fails for a reason that is not a lost Lease: every Lease in the
            // Journal is still this run's, so no Lease-guarded write stops the run on its own.
            beatFails.withLock { $0 = true }
            try await waitForCancellation()
        }
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(log: log)
        )

        // The same nesting EngineInvocation gives a build Act's work.
        await #expect(throws: TransientBeatFailure.self) {
            try await withLeaseHeartbeat(
                every: .milliseconds(20),
                beat: { if beatFails.withLock({ $0 }) { throw TransientBeatFailure() } },
                body: { try await run.run("BACK-1", in: world) }
            )
        }

        try expectReclaimable(world: world, cardID: cardID, log: log, expectedDetail: "the run was cancelled")
    }

    @Test("An Act Lease lost mid-pass through the build Act: at most one Attempt, the Card reclaimable, not Blocked")
    func lostActLeaseThroughTheBuildAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        try await initReconcilerGitRepo(
            at: worktrees.appending(component: "backend"), git: GitRunner(), branch: buildActBranch.name
        )
        let world = try await makeCardRunWorld(
            journal: journal, worktreePath: { worktrees.appending(component: $0).path(percentEncoded: false) }
        )
        let cardID = try #require(world.cardIDs["BACK-1"])
        let runID = world.runID
        let other = RunID()
        let log = CallLog()
        let dispatch = AbortingOnCancelDispatch(log: log) { pass in
            guard pass == .worker else { return }
            // Another run takes the Project over while the worker is still running.
            try journal.releaseActLease(runID: runID)
            _ = try journal.claimActLease(act: .build, runID: other, mode: .rehearsal)
            try await waitForCancellation()
        }
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(log: log)
        )
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, leasePolicy: LeasePolicy(heartbeatInterval: 0.05, timeToLive: 600),
            board: try #require(world.context.act.board), workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: run).work
        )

        await #expect(throws: JournalError.self) {
            try await invocation.run()
        }

        // Reaches CardRun as a plain CancellationError (the outer heartbeat's own failure, not
        // `JournalError.actLeaseLost` directly), so the recorded cause is the generic one.
        try expectReclaimable(world: world, cardID: cardID, log: log, expectedDetail: "the run was cancelled")
        #expect(try journal.currentActLease()?.runID == other)
    }

    /// What a cancelled Card run leaves behind: the one Attempt the cancellation interrupted, nothing
    /// dispatched after it, the Card still In Progress (never Blocked, never Done), no reset run, and the
    /// Card Lease still this run's, left to expire for the next build Act's Expired Lease Sweep.
    private func expectReclaimable(
        world: CardRunWorld, cardID: Int64, log: CallLog, expectedDetail: String? = nil
    ) throws {
        #expect(log.all == ["dispatch architect", "dispatch worker"])
        #expect(try world.attempts("BACK-1").count == 1)
        #expect(try world.card("BACK-1").state == .inProgress)
        let story = try cardRunLog(world.journal)
        #expect(!story.contains(CardRunStep.attemptsExhausted.rawValue))
        #expect(!story.contains(CardRunStep.attemptReset.rawValue))
        #expect(!story.contains("→ \(CardState.blocked.rawValue)"))
        #expect(!story.contains(CardRunStep.leaseReleased.rawValue))
        #expect(try world.journal.currentCardLease(cardID: cardID)?.runID == world.runID)

        // The terminal step the engine's stop recorded (OQ92): last, after the worker pass, detail
        // non-nil so the next Act's Expired Lease Sweep can tell this apart from a real crash.
        let steps = try cardRunSteps(world.journal, cardID: cardID)
        let last = try #require(steps.last)
        #expect(last.step == .leaseLeftToExpire)
        let workerIndex = try #require(steps.firstIndex { $0.step == .worker })
        #expect(steps.count - 1 > workerIndex)
        let detail = try #require(last.detail)
        #expect(!detail.isEmpty)
        if let expectedDetail {
            #expect(detail == expectedDetail)
        }
    }
}

struct TransientBeatFailure: Error {}

/// Holds a pass open until the run is cancelled, polling rather than sleeping through it: a
/// `Task.sleep` would throw `CancellationError` out of the dispatch, which the real adapter never does.
func waitForCancellation() async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !Task.isCancelled {
        guard ContinuousClock.now < deadline else {
            Issue.record("The Card run was never cancelled")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A Dispatch seam that behaves like `AgentCLIProcess` under cancellation: a pass that finds its task
/// cancelled does not throw, it comes back `aborted`, which classifies as Crashed-Unknown. Otherwise
/// it answers from ``RehearsalDispatch``.
struct AbortingOnCancelDispatch: AgentDispatch {
    let log: CallLog
    let during: @Sendable (RunPass) async throws -> Void

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        log.add("dispatch \(request.pass.rawValue)")
        try await during(request.pass)
        if Task.isCancelled {
            return AgentDispatchReport(outcome: .crashedUnknown(.terminated(.aborted(forcedKill: false))))
        }
        return try await RehearsalDispatch().dispatch(request)
    }
}
