import Darwin
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// loop-state/reclaim-an-expired-lease (P8.10), the roadmap's own "done when": a rehearsal kills a real
// engine invocation mid-Card, and the next build Act reclaims within the TTL, with the right
// classification. No seeded Journal state stands in for the crash here — a real child process is
// spawned by a real worker-pass dispatch, and the invocation is genuinely killed by Task cancellation
// while that dispatch is suspended on a continuation that ignores it, exactly as a killed `yh` process
// would leave its own agent CLI subprocess orphaned. The first invocation runs on the ruled 600s Lease
// policy — under the parallel suite's cooperative-pool hops (0.5–1.5s are normal in this repo), a short
// TTL can expire the dead run's own Lease before its worker pass is even dispatched, which would make
// this test hang on its own `waitUntilReady()` rather than exercise a reclaim at all. Once the kill has
// happened, "the clock passing" is simulated directly on the Lease rows (see `backdateLeases` below)
// instead of a real sleep, since `EngineInvocation` takes no injectable clock.

/// Suspends a worker pass until released, and never resumes on Task cancellation: deliberately not
/// `withTaskCancellationHandler`, so cancelling the Task that runs the dispatch leaves it hung — the
/// heartbeat's `Task.sleep` throws and stops, but the body never does, which is the kill.
private actor KillSwitch {
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var readySignaled = false
    private var hangContinuation: CheckedContinuation<Void, Error>?
    private(set) var childPID: pid_t?

    func recordChild(pid: pid_t) {
        childPID = pid
    }

    /// Resumes `waitUntilReady()`, or marks ready immediately if nothing is waiting yet.
    func signalReady() {
        readySignaled = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    func waitUntilReady() async {
        if readySignaled { return }
        await withCheckedContinuation { readyContinuation = $0 }
    }

    /// Suspends the caller until ``release(with:)`` is called from outside — never on its own, and never
    /// on cancellation.
    func hangUntilReleased() async throws {
        try await withCheckedThrowingContinuation { hangContinuation = $0 }
    }

    /// Teardown only: unblocks a suspended `hangUntilReleased()` with `error`.
    func release(with error: Error) {
        hangContinuation?.resume(throwing: error)
        hangContinuation = nil
    }
}

/// The architect and reviewer passes answer instantly from ``RehearsalDispatch``; the worker pass spawns
/// a real, long-lived child in the Worktree, signals ``KillSwitch/waitUntilReady()``, and then hangs.
private struct KillableWorkerDispatch: AgentDispatch {
    let gate: KillSwitch

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        guard request.pass == .worker else {
            return try await RehearsalDispatch().dispatch(request)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["600"]
        process.currentDirectoryURL = URL(fileURLWithPath: request.worktreePath)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        await gate.recordChild(pid: process.processIdentifier)
        await gate.signalReady()
        try await gate.hangUntilReleased()
        throw CancellationError()
    }
}

private struct RealKillTeardownError: Error {}

/// Delivers exactly one value to whichever of several racing producers gets there first; every later
/// `deliver` is a no-op. Used so a race never has to await an unstructured loser Task's own completion —
/// an unawaited `Task` simply runs to completion on its own and is never a source of a hang, unlike a
/// child of a `TaskGroup`, which the group's exit would wait for.
private actor SingleResultBox<T: Sendable> {
    private var value: T?
    private var continuation: CheckedContinuation<T, Never>?

    func deliver(_ result: T) {
        guard value == nil else { return }
        value = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func wait() async -> T {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }
}

/// What won the race in ``waitForDispatchOrGiveUp(gate:firstTask:timeout:)``.
private enum DispatchWait {
    case ready(pid_t)
    /// The first invocation finished (however it finished) before ever reaching the worker dispatch.
    case firstTaskFinishedEarly(Result<Void, Error>)
    case timedOut
}

/// Races "the worker dispatch signalled ready" against "the first invocation already finished" against
/// a generous timeout, so this test can never hang here: under bad enough scheduling the dead run's own
/// Lease work could in principle still be starved, in which case this reports why instead of waiting
/// forever.
private func waitForDispatchOrGiveUp(
    gate: KillSwitch, firstTask: Task<Void, Error>, timeout: Duration
) async -> DispatchWait {
    let box = SingleResultBox<DispatchWait>()
    Task {
        await gate.waitUntilReady()
        await box.deliver(.ready(await gate.childPID ?? -1))
    }
    Task {
        let outcome: Result<Void, Error>
        do {
            try await firstTask.value
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await box.deliver(.firstTaskFinishedEarly(outcome))
    }
    Task {
        try? await Task.sleep(for: timeout)
        await box.deliver(.timedOut)
    }
    return await box.wait()
}

/// Awaits `task`, but never unconditionally: a bounded wait, same reasoning as
/// ``waitForDispatchOrGiveUp(gate:firstTask:timeout:)`` — an unstructured loser `Task` here just finishes
/// on its own later and is never a source of a hang.
private func awaitWithTimeout(_ task: Task<Void, Error>, timeout: Duration) async {
    let box = SingleResultBox<Void>()
    Task {
        _ = try? await task.value
        await box.deliver(())
    }
    Task {
        try? await Task.sleep(for: timeout)
        await box.deliver(())
    }
    await box.wait()
}

/// Test-only: stands in for the clock passing, since `EngineInvocation` takes no injectable clock. Moves
/// `runID`'s Act Lease and Card Lease rows `interval` further into the past, through the same
/// `journal.write` direct-schema access the reconciler fixtures already use elsewhere in this target.
private func backdateLeases(_ journal: JournalStore, runID: RunID, by interval: TimeInterval) throws {
    try journal.write { db in
        // `act_lease` is a single row (`id = 1`); `lease` is one row per Card, keyed by `card_id`. Each
        // is updated by its own key rather than a shared `rowid` column, which `act_lease` (declared
        // `id INTEGER PRIMARY KEY`) reports under its own column name, not literally "rowid".
        try backdate(db, table: "act_lease", keyColumn: "id", runID: runID, by: interval)
        try backdate(db, table: "lease", keyColumn: "card_id", runID: runID, by: interval)
    }
}

private func backdate(
    _ db: Database, table: String, keyColumn: String, runID: RunID, by interval: TimeInterval
) throws {
    let rows = try Row.fetchAll(
        db, sql: "SELECT \(keyColumn) AS key, expires_at FROM \(table) WHERE run_id = ?", arguments: [runID.rawValue]
    )
    for row in rows {
        let key: DatabaseValue = row["key"]
        let expiresAtText: String = row["expires_at"]
        let expiresAt = try JournalStore.date(expiresAtText) { JournalError.actLeaseUnreadable }
        let backdated = expiresAt.addingTimeInterval(-interval)
        try db.execute(
            sql: "UPDATE \(table) SET expires_at = ? WHERE \(keyColumn) = ?",
            arguments: [JournalStore.timestamp(backdated), key]
        )
    }
}

@Suite("ExpiredLeaseSweep: a real killed invocation (P8.10 done-when)")
struct ExpiredLeaseSweepRealKillTests {
    @Test(
        "A rehearsal kills a real engine invocation mid-Card; the next build Act reclaims within the TTL",
        .enabled(if: FileManager.default.fileExists(atPath: "/bin/sleep"))
    )
    func realKillIsReclaimedByTheNextBuildAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let git = GitRunner()
        let worktree = fixture.directory.appending(component: "worktree", directoryHint: .isDirectory)
        try await initReconcilerGitRepo(at: worktree, git: git, branch: buildActBranch.name)

        let featureID = try insertReconcilerFeature(journal, issueID: "KILL-FEAT")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "KILL-1", repository: "backend", state: .todo
        )

        let killSwitch = KillSwitch()
        let deadRunID = RunID()
        // The ruled Lease policy, deliberately: a short one can expire the dead run's own Act or Card
        // Lease before its worker pass is even dispatched under the parallel suite's scheduling hops,
        // which would starve `waitUntilReady()` rather than exercise a reclaim.
        let firstRun = CardRun(
            resolver: cardRunResolver(), dispatch: KillableWorkerDispatch(gate: killSwitch),
            check: RecordingCheck(log: CallLog()), checks: ["backend": .none], reviewRoundsMax: 2,
            attemptsPerCard: 3, resetting: RecordingAttemptResetting()
        )
        let firstInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal, runID: deadRunID,
            workspace: ReconcilerFakeWorkspace(), work: BuildAct(cardRunner: firstRun).work
        )

        // `recordWorktree` writes under the Act-scoped Lease, so it is claimed (as the dead run) just
        // long enough to record the fixture, then released — `firstInvocation.run()` claims it again,
        // fresh, the moment it starts.
        guard case .claimed = try journal.claimActLease(act: .build, runID: deadRunID, mode: .rehearsal) else {
            Issue.record("Could not claim the Act lease for fixture setup")
            return
        }
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: deadRunID
        )
        _ = try journal.releaseActLease(runID: deadRunID)

        let killedTask = Task { try await firstInvocation.run() }

        // Swift's `defer` cannot `await`, so teardown is explicit on both paths below rather than
        // deferred: a fire-and-forget `Task` in a `defer` would let this test report done while its own
        // cleanup was still racing unrelated tests for the cooperative pool. `killedTask` is always
        // awaited (with a bound) before this function returns, on every path.
        do {
            try await runAndAssert(
                journal: journal, killSwitch: killSwitch, killedTask: killedTask, deadRunID: deadRunID, cardID: cardID
            )
        } catch {
            await killSwitch.release(with: RealKillTeardownError())
            await awaitWithTimeout(killedTask, timeout: .seconds(10))
            throw error
        }
        await killSwitch.release(with: RealKillTeardownError())
        await awaitWithTimeout(killedTask, timeout: .seconds(10))
    }

    /// Everything after the kill: waits for the real orphan (bounded — never hangs), backdates the dead
    /// run's Leases to stand in for the clock passing, runs the second (retrying) build Act, and asserts
    /// the whole story. Split out of the Test function so teardown around it stays a plain `do`/`catch`,
    /// not a non-awaitable `defer`.
    private func runAndAssert(
        journal: JournalStore, killSwitch: KillSwitch, killedTask: Task<Void, Error>, deadRunID: RunID, cardID: Int64
    ) async throws {
        let childPID: pid_t
        switch await waitForDispatchOrGiveUp(gate: killSwitch, firstTask: killedTask, timeout: .seconds(30)) {
        case .ready(let pid):
            childPID = pid
        case .firstTaskFinishedEarly(let result):
            Issue.record("the first invocation finished before reaching the worker dispatch: \(result)")
            return
        case .timedOut:
            Issue.record("timed out waiting for the worker dispatch to start")
            return
        }
        killedTask.cancel()

        // The child is a real orphan now: the engine that spawned it never gets to clean it up, because
        // the body of `withLeaseHeartbeat` is hung on `hangUntilReleased()`, ignoring cancellation.
        #expect(kill(childPID, 0) == 0)

        // Stands in for the clock passing (`EngineInvocation` takes no injectable clock): the dead run's
        // Act and Card Leases are moved 11 minutes past their claim, comfortably past the ruled 600s TTL
        // regardless of how long the kill itself took under load. The kill, the orphaned child and the
        // open Attempt are all still real; only the wait for the TTL is simulated.
        try backdateLeases(journal, runID: deadRunID, by: 11 * 60)

        let retryRunID = RunID()
        let retryRun = CardRun(
            resolver: cardRunResolver(), dispatch: RehearsalDispatch(), check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3, resetting: RecordingAttemptResetting()
        )
        let fastFencer = ProcessFencer(pollInterval: .milliseconds(20), quiescenceTimeout: .seconds(5))
        let secondInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal, runID: retryRunID,
            workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: retryRun, worktreeFencer: fastFencer).work
        )
        try await secondInvocation.run()

        // The orphaned sleep is dead: the Pre-Reclaim Quiescence Gate (or the Worktree reconciliation
        // right after it) fenced it before anything else touched the Card or the Worktree.
        #expect(kill(childPID, 0) == -1)

        try assertReclaimed(journal: journal, deadRunID: deadRunID, retryRunID: retryRunID, cardID: cardID)
    }

    /// The story `runAndAssert` checks once the second build Act has run: the dead Lease reclaimed under
    /// its name, the Attempt classified Crashed-Unknown and retried on the same Route, `.cardReclaimed`
    /// stamped with the second Act's own Night, and the Card retried through to Done. Split out to keep
    /// `runAndAssert` under the file's function-length limit.
    private func assertReclaimed(journal: JournalStore, deadRunID: RunID, retryRunID: RunID, cardID: Int64) throws {
        let leaseReclaimed = try journal.events(ofType: .cardLeaseReclaimed)
        guard case .cardLeaseReclaimed(_, let previousRunID, _) = try #require(leaseReclaimed.first).event else {
            Issue.record("expected cardLeaseReclaimed")
            return
        }
        #expect(previousRunID == deadRunID)

        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.attempts.count == 2)
        let reclaimedAttempt = try #require(history.attempts.first)
        #expect(reclaimedAttempt.result == AttemptOutcome.crashedUnknown.rawValue)
        #expect(reclaimedAttempt.classification?.hasPrefix("reclaimed:") == true)
        let retriedAttempt = try #require(history.attempts.last)
        #expect(retriedAttempt.route == reclaimedAttempt.route)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)

        let cardReclaimedEvents = try journal.events(ofType: .cardReclaimed)
        let cardReclaimedRecord = try #require(cardReclaimedEvents.first)
        guard case .cardReclaimed(let reclaimedCardID, _, let reclaimedPreviousRunID, _, _, let routeExcluded) =
            cardReclaimedRecord.event
        else {
            Issue.record("expected cardReclaimed")
            return
        }
        #expect(reclaimedCardID == cardID)
        #expect(reclaimedPreviousRunID == deadRunID)
        #expect(routeExcluded == false)

        // Stamped with the second Act's own nightID, not the first's — read from the last `ActStarted`,
        // which is this second invocation's.
        let actStarted = try journal.events(ofType: .actStarted)
        let secondNightID = try #require(actStarted.last?.nightID)
        #expect(cardReclaimedRecord.nightID == secondNightID)

        // Retried: the same Route, the Card back through Todo then dispatched again in this same Act.
        #expect(try journal.card(id: cardID).state == .done)

        // The Card Lease is the new run's, or already released by it (the retry completed).
        let lease = try journal.currentCardLease(cardID: cardID)
        #expect(lease == nil || lease?.runID == retryRunID)
    }
}
