import Darwin
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// Issue #151: `yh` installed no signal handler, so `launchd` or the Operator's SIGTERM/SIGINT killed it
// outright — the abort path (`AgentCLIProcess.wait` checking `Task.isCancelled`, `CardRun` (#150)
// stopping at the next Attempt boundary, `EngineInvocation.runUnderLease` appending `.actIncomplete`)
// never ran, and the agent CLI, in its own process group, survived and kept running in the Worktree.
//
// `.serialized`: signal dispositions (`sigaction`) are global to the process, so these tests must not
// interleave with each other. They may still run alongside other suites in the same test process —
// mostly harmless, since only these tests ever send a signal. `ActGesturesTests` does route through
// `ActCommand.run(configurationDirectory:)`, which now installs and restores handlers too (it never
// sends a signal), so a signal sent here could in principle land during another suite's narrow
// install/restore window; not observed, and out of scope to engineer around (see the brief's Open
// points in the report).
@Suite("Termination signals", .serialized, .timeLimit(.minutes(1)))
struct TerminationSignalsTests {
    // MARK: - Plumbing

    @Test("The first signal cancels the body; the body finishing promptly never calls exit")
    func firstSignalCancelsBody() async throws {
        let exitCalls = Mutex<[Int32]>([])
        let bodyStarted = DispatchSemaphore(value: 0)
        let bodyObservedCancellation = Mutex(false)

        try? await TerminationSignals.run(
            deadline: .seconds(5),
            exit: { code in exitCalls.withLock { $0.append(code) } },
            signalHook: { hook in
                DispatchQueue.global().async {
                    bodyStarted.wait()
                    hook(SIGTERM)
                }
            },
            body: {
                bodyStarted.signal()
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !Task.isCancelled {
                    guard ContinuousClock.now < deadline else { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                bodyObservedCancellation.withLock { $0 = Task.isCancelled }
            }
        )

        #expect(bodyObservedCancellation.withLock { $0 })
        #expect(exitCalls.withLock { $0 }.isEmpty)
    }

    @Test("A second signal exits at once with 128 + signal number")
    func secondSignalExitsAtOnce() async throws {
        let exitCalls = Mutex<[Int32]>([])
        let bodyStarted = DispatchSemaphore(value: 0)

        // Ignores cancellation entirely — this body never checks `Task.isCancelled` — but returns
        // once the second signal's exit call is observed, so the test does not depend on the
        // (never-returning, in production) `exit` closure to unblock `task.value`. The `exit`
        // closure below only records the call and returns — it must not itself block: a closure
        // that parks its calling thread forever (e.g. waiting on a semaphore nothing signals) would
        // permanently consume one of libdispatch's limited worker threads and starve later signal
        // delivery in other tests of this suite (found empirically as an intermittent flake).
        try? await TerminationSignals.run(
            deadline: .seconds(5),
            exit: { code in exitCalls.withLock { $0.append(code) } },
            signalHook: { hook in
                DispatchQueue.global().async {
                    bodyStarted.wait()
                    hook(SIGTERM)
                    hook(SIGINT)
                }
            },
            body: {
                bodyStarted.signal()
                while exitCalls.withLock({ $0.isEmpty }) {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        #expect(exitCalls.withLock { $0 } == [Int32(128 + SIGINT)])
    }

    @Test("The deadline exits when the body ignores cancellation")
    func deadlineExitsWhenBodyIgnoresCancellation() async throws {
        let exitCalls = Mutex<[Int32]>([])
        let bodyStarted = DispatchSemaphore(value: 0)
        let exitObserved = Mutex<Int32?>(nil)

        // See `secondSignalExitsAtOnce`: `exit` only records and returns, never blocks.
        try? await TerminationSignals.run(
            deadline: .milliseconds(200),
            exit: { code in
                exitCalls.withLock { $0.append(code) }
                exitObserved.withLock { $0 = code }
            },
            signalHook: { hook in
                DispatchQueue.global().async {
                    bodyStarted.wait()
                    hook(SIGTERM)
                }
            },
            body: {
                bodyStarted.signal()
                // Ignores cancellation entirely, but returns once the deadline's exit call is
                // observed, so the test does not hang waiting on a task that never finishes.
                while exitObserved.withLock({ $0 }) == nil {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        )

        #expect(exitCalls.withLock { $0 } == [Int32(128 + SIGTERM)])
    }

    @Test("A body ended by a signal throws a clear, non-CancellationError describing the interruption")
    func interruptedErrorDescribesTheSignal() async throws {
        let bodyStarted = DispatchSemaphore(value: 0)

        await #expect(throws: TerminationSignals.InterruptedError.self) {
            try await TerminationSignals.run(
                deadline: .seconds(5),
                exit: { _ in },
                signalHook: { hook in
                    DispatchQueue.global().async {
                        bodyStarted.wait()
                        hook(SIGTERM)
                    }
                },
                body: {
                    bodyStarted.signal()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                    while !Task.isCancelled {
                        guard ContinuousClock.now < deadline else { break }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    throw CancellationError()
                }
            )
        }
    }

    @Test("A real SIGTERM, delivered through kill(getpid(), _), is observed by the installed handler")
    func realSignalIsObservedByHandler() async throws {
        let cancelled = Mutex(false)
        let exitCalls = Mutex<[Int32]>([])

        try? await TerminationSignals.run(
            deadline: .seconds(5),
            exit: { code in exitCalls.withLock { $0.append(code) } },
            body: {
                // The handler can only be installed by the time this body runs: sending the real signal
                // from inside it is the proof that the DispatchSource + `sigaction` wiring works, not a
                // race against installation.
                #expect(kill(getpid(), SIGTERM) == 0)
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !Task.isCancelled {
                    guard ContinuousClock.now < deadline else { break }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                cancelled.withLock { $0 = Task.isCancelled }
            }
        )

        #expect(cancelled.withLock { $0 })
        #expect(exitCalls.withLock { $0 }.isEmpty)
    }
}

// MARK: - Integration: the issue's acceptance

extension TerminationSignalsTests {
    /// A stub `claude` CLI that ignores SIGTERM, escapes its own process group before that, and keeps
    /// running — modelled on `StubAgentCLI.escapedChildIgnoresTerm`. Paths are baked into the script
    /// text directly (the stub may ignore its argv/environment, per the brief), so the dispatch's own
    /// arguments never need to line up with anything this script reads.
    private static func escapingStubScript(readyFile: URL, leaderPIDFile: URL, childPIDFile: URL) -> String {
        """
        #!/bin/sh
        trap '' TERM
        echo $$ > "\(leaderPIDFile.path)"
        /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV' /bin/sh -c '
            trap "" TERM
            echo $$ > "\(childPIDFile.path)"
            exec sleep 60
        ' &
        echo ready > "\(readyFile.path)"
        exec sleep 60
        """
    }

    private static func isDead(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    private static func waitForFile(_ url: URL, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func readPID(_ url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("A real SIGTERM mid-build stops the run without killing the process, and contains the CLI")
    func sigtermMidBuildStopsTheRunAndContainsTheCLI() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        try await initReconcilerGitRepo(at: worktrees.appending(component: "backend"), git: GitRunner())
        let world = try await makeCardRunWorld(
            journal: journal, worktreePath: { worktrees.appending(component: $0).path(percentEncoded: false) }
        )

        let stub = try Self.makeEscapingStub(in: fixture.directory)
        let invocation = Self.makeBuildInvocation(journal: journal, world: world, stubExecutable: stub.scriptPath)

        let exitCalls = Mutex<[Int32]>([])
        let recordExit: @Sendable (Int32) -> Void = { code in exitCalls.withLock { $0.append(code) } }
        let runTask = Task {
            try await TerminationSignals.run(deadline: .seconds(10), exit: recordExit) {
                try await invocation.run()
            }
        }

        try await Self.awaitStubReady(stub)
        let leaderPID = Self.readPID(stub.leaderPIDFile)
        let childPID = Self.readPID(stub.childPIDFile)
        #expect(leaderPID != nil)
        #expect(childPID != nil)

        let signalledAt = ContinuousClock.now
        #expect(kill(getpid(), SIGTERM) == 0)

        await #expect(throws: (any Error).self) {
            try await runTask.value
        }
        // The 3 s abort grace plus escalation, not the injected 10 s deadline: a broken abort path
        // must not silently pass by hanging until the deadline forces an (unobserved, in this test)
        // exit — bounding elapsed time catches that.
        #expect(ContinuousClock.now - signalledAt < .seconds(10))
        #expect(exitCalls.withLock { $0 }.isEmpty)

        if let leaderPID { await Self.expectDeadEventually(leaderPID, description: "the stub CLI leader") }
        if let childPID {
            await Self.expectDeadEventually(childPID, description: "the escaped, SIGTERM-ignoring child")
        }

        try Self.expectReclaimableAfterSignal(journal: journal, world: world, runID: world.runID)
    }

    /// The stub CLI's files, plus assertion that it (and its escaped child) started.
    private static func awaitStubReady(_ stub: EscapingStub) async throws {
        let sawReady = await Self.waitForFile(stub.readyFile)
        #expect(sawReady, "the stub CLI never signalled readiness")
        let sawLeaderPID = await Self.waitForFile(stub.leaderPIDFile)
        #expect(sawLeaderPID, "the stub CLI never recorded its own pid")
        let sawChildPID = await Self.waitForFile(stub.childPIDFile)
        #expect(sawChildPID, "the escaped child never recorded its own pid")
    }

    private static func expectDeadEventually(_ pid: pid_t, description: String) async {
        var stillAlive = true
        for _ in 0..<50 where stillAlive {
            stillAlive = !Self.isDead(pid)
            if stillAlive { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(Self.isDead(pid), "\(description) is still alive")
    }

    /// What a run the engine stopped by signal leaves behind: no `ActEnded`, an `ActIncomplete`, one
    /// still-open Attempt, and the Card still In Progress — the same reclaimability #150 established
    /// for engine-initiated cancellation, now reached through a real SIGTERM.
    private static func expectReclaimableAfterSignal(journal: JournalStore, world: CardRunWorld, runID: RunID) throws {
        let events = try journal.events().filter { $0.runID == runID }
        #expect(events.contains { $0.type == .actIncomplete })
        #expect(!events.contains { $0.type == .actEnded })

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts.first?.isOpen == true)

        #expect(try world.card("BACK-1").state == .inProgress)
    }

    private struct EscapingStub {
        let scriptPath: URL
        let readyFile: URL
        let leaderPIDFile: URL
        let childPIDFile: URL
    }

    private static func makeEscapingStub(in directory: URL) throws -> EscapingStub {
        let scratch = directory.appending(component: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let readyFile = scratch.appending(component: "ready")
        let leaderPIDFile = scratch.appending(component: "leader.pid")
        let childPIDFile = scratch.appending(component: "child.pid")
        let scriptPath = scratch.appending(component: "claude-stub.sh")
        try Self.escapingStubScript(readyFile: readyFile, leaderPIDFile: leaderPIDFile, childPIDFile: childPIDFile)
            .write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return EscapingStub(
            scriptPath: scriptPath, readyFile: readyFile, leaderPIDFile: leaderPIDFile, childPIDFile: childPIDFile
        )
    }

    private static func makeBuildInvocation(
        journal: JournalStore, world: CardRunWorld, stubExecutable: URL
    ) -> EngineInvocation {
        let runsDirectory = stubExecutable.deletingLastPathComponent().appending(component: "runs")
        let dispatch = CLIAdapterDispatch(
            runsDirectory: runsDirectory,
            declaredExecutables: ["claude": stubExecutable.path],
            path: nil,
            environment: [:]
        )
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting()
        )
        return EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: world.runID, leasePolicy: LeasePolicy(heartbeatInterval: 0.05, timeToLive: 600),
            board: world.context.act.board, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: run).work
        )
    }
}
