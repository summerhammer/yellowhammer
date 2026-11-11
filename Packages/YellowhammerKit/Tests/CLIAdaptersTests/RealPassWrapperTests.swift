import CLIAdapters
import Darwin
import Domain
import Foundation
import ProcessTestSupport
import Repositories
import Testing

private struct NoPassPromptSource: PromptSource {
    func start() async -> (any PromptWatching)? { nil }
}

private actor FixedPassPromptWatch: PromptWatching {
    private let event: PromptEvent
    private var emitted = false

    init(event: PromptEvent) { self.event = event }

    func drain() -> [PromptEvent] {
        guard !emitted else { return [] }
        emitted = true
        return [event]
    }

    func stop() {}
}

private struct FixedPassPromptSource: PromptSource {
    let event: PromptEvent
    func start() async -> (any PromptWatching)? { FixedPassPromptWatch(event: event) }
}

private actor FirstDrainBarrier: PromptWatching {
    private var drained = false
    private var continuation: CheckedContinuation<Void, Never>?

    func drain() -> [PromptEvent] {
        if !drained {
            drained = true
            continuation?.resume()
            continuation = nil
        }
        return []
    }

    func waitForFirstDrain() async {
        if drained { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func stop() {}
}

private struct FirstDrainBarrierSource: PromptSource {
    let barrier: FirstDrainBarrier
    func start() async -> (any PromptWatching)? { barrier }
}

@Suite("Pass wrapper real process boundary", .serialized, .timeLimit(.minutes(3)))
struct RealPassWrapperTests {
    @Test("exit and signal endings keep exit 137 distinct from SIGKILL")
    func parsesRealProcessEndings() async throws {
        for (script, expectedStatus, expectedEnding) in [
            ("exit 0", Int32(0), "exit 0"),
            ("exit 1", Int32(1), "exit 1"),
            ("exit 127", Int32(127), "exit 127"),
            ("exit 137", Int32(137), "exit 137"),
            ("kill -KILL $$\nwait", Int32(137), "signal 9")
        ] {
            let fixture = try RealPassWrapperHarness.makeFixture(script: script)
            defer { fixture.cleanUp() }
            let wrapper = try fixture.launch()
            let status = await wrapper.waitForExit()

            #expect(status == .exited(expectedStatus))
            #expect(fixture.read("ending")?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedEnding)
            let parsed = try #require(PassWrapperEnding.read(from: fixture.endingFile))
            if expectedEnding.hasPrefix("exit") {
                #expect(parsed.exited)
                #expect(parsed.value == Int32(expectedEnding.split(separator: " ")[1])!)
            } else {
                #expect(!parsed.exited)
                #expect(parsed.value == SIGKILL)
            }
        }
    }

    @Test("an exec failure has no ending while a CLI that exits 127 does")
    func nonexistentExecutableDoesNotLookLikeExit127() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: "exit 0")
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.cli)
        let wrapper = try fixture.launch()
        let status = await wrapper.waitForExit()

        #expect(status == .exited(71))
        #expect(PassWrapperEnding.read(from: fixture.endingFile) == nil)
    }

    @Test("identity records match the real session and group; stdin is null and binary stdout is exact")
    func identityAndStandardStreams() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(
            script: #"""
if read -r line; then echo readable > "$1/stdin"; else echo eof > "$1/stdin"; fi
/usr/bin/perl -e 'print "x" x 50000, "\0", "z"'
echo streams-written > "$1/streams-ready"
until [ -f "$1/release" ]; do /bin/sleep 0.01; done
"""#,
            arguments: []
        )
        defer { fixture.cleanUp() }
        let wrapper = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("identity")))
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("streams-ready")))

        let record = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
        fixture.track(record.cliPID)
        #expect(record.wrapperPID == wrapper.pid)
        #expect(record.cliPID == record.processGroup)
        #expect(record.cliPID == record.session)
        #expect(record.session != getsid(0))
        #expect(getsid(record.wrapperPID) == getsid(0))
        #expect(record.wrapperPID != record.cliPID)

        let actualCLI = try #require(kernelIdentity(record.cliPID))
        let actualWrapper = try #require(kernelIdentity(record.wrapperPID))
        #expect(actualCLI.start == (record.cliStartSeconds, record.cliStartMicroseconds))
        #expect(actualWrapper.start == (record.wrapperStartSeconds, record.wrapperStartMicroseconds))
        #expect(actualCLI.group == record.processGroup)
        #expect(actualCLI.session == record.session)

        let expectedOutput = Data(repeating: 120, count: 50_000) + Data([0, 122])
        #expect(try Data(contentsOf: fixture.stdoutFile) == expectedOutput)
        #expect(fixture.read("stdin")?.trimmingCharacters(in: .whitespacesAndNewlines) == "eof")

        try Data().write(to: fixture.directory.appendingPathComponent("release"))
        #expect(await wrapper.waitForExit() == .exited(0))
        #expect(PassWrapperEnding.read(from: fixture.endingFile)?.exited == true)
    }

    @Test("HUP, TERM and INT are logged with their sender and never forwarded to the CLI")
    func wrapperSignalsAreObservedOnly() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: #"""
echo ready > "$1/ready"
until [ -f "$1/release" ]; do /bin/sleep 0.01; done
"""#)
        defer { fixture.cleanUp() }
        let wrapper = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("ready")))
        let identity = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
        fixture.track(identity.cliPID)

        for (index, signal) in [SIGHUP, SIGTERM, SIGINT].enumerated() {
            #expect(kill(wrapper.pid, signal) == 0)
            #expect(await awaitSignalCount(fixture, expected: index + 1))
            #expect(kernelIdentity(identity.cliPID) != nil)
        }
        let events = PassWrapperSignalEvent.readAll(from: fixture.signalFile)
        #expect(events.map(\.signal) == [SIGHUP, SIGTERM, SIGINT])
        #expect(events.allSatisfy { $0.senderPID == getpid() })
        #expect(events.allSatisfy { $0.seconds > 0 && (0..<1_000_000).contains($0.microseconds) })

        for iteration in 0..<2 {
            #expect(kill(wrapper.pid, SIGTSTP) == 0)
            #expect(await awaitPassWrapperStopped(wrapper.pid))
            #expect(await awaitSignalCount(fixture, expected: 4 + iteration * 2))
            #expect(kill(wrapper.pid, SIGCONT) == 0)
            #expect(await awaitSignalCount(fixture, expected: 5 + iteration * 2))
            #expect(kernelIdentity(identity.cliPID) != nil)
        }
        #expect(PassWrapperSignalEvent.readAll(from: fixture.signalFile).map(\.signal)
            == [SIGHUP, SIGTERM, SIGINT, SIGTSTP, SIGCONT, SIGTSTP, SIGCONT])

        try Data().write(to: fixture.directory.appendingPathComponent("release"))
        #expect(await wrapper.waitForExit() == .exited(0))
    }

    @Test("a catchable non-terminal signal is logged and retains its ordinary wrapper disposition")
    func otherSignalIsLoggedAndReraised() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: Self.readyThenSleep)
        defer { fixture.cleanUp() }
        let wrapper = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("ready")))
        let identity = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
        fixture.track(identity.cliPID)
        #expect(kill(wrapper.pid, SIGUSR1) == 0)
        let status = await wrapper.waitForExit()

        #expect(status == .signalled(SIGUSR1))
        let event = try #require(PassWrapperSignalEvent.readAll(from: fixture.signalFile).first)
        #expect(event.signal == SIGUSR1)
        #expect(event.senderPID == getpid())
        #expect(kernelIdentity(identity.cliPID) != nil)
    }

    @Test("rapid ordinary exit remains observable after both wrapper and CLI have exited")
    func rapidExitCanBeMonitoredAfterTheFact() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: "exit 0")
        defer { fixture.cleanUp() }
        let wrapper = try fixture.launch()
        #expect(await wrapper.waitForExit() == .exited(0))

        let execution = await monitor(fixture, timeout: .seconds(2))
        #expect(execution.end == .exited(status: 0))
        #expect(execution.pid > 0)
        #expect(!execution.snapshot.sessions.contains(getsid(0)))
        #expect(!execution.snapshot.processGroups.contains(getpgrp()))
    }

    @Test("startup timeout cancels a wrapper that is launched late before its CLI executes")
    func startupTimeoutStopsLateWrapperExec() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: "echo executed > \"$1/executed\"")
        defer { fixture.cleanUp() }
        let execution = await monitor(fixture, timeout: .milliseconds(50))
        #expect(execution.end == .wrapperLost)
        #expect(FileManager.default.fileExists(atPath: fixture.identityFile.path + ".cancel"))

        let wrapper = try fixture.launch()
        #expect(await wrapper.waitForExit() == .exited(125))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("executed").path))
        #expect(PassWrapperEnding.read(from: fixture.endingFile)?.value == 125)
    }

    @Test("the attributed Worktree fence spares the real shell that launched the wrapper")
    func attributedFenceSparesLaunchingShell() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: "exit 0")
        defer { fixture.cleanUp() }
        // Dispatch precedes the tab: the engine records dispatch before Orca ADE creates the shell,
        // so the shell started after dispatch and the fence reports it as unattributed.
        let dispatchedAt = processStartTimeNow()
        let shell = try launchingShell(for: fixture)
        let spawned = makeSpawnStream()
        let task = Task {
            await AgentCLIProcess(
                gracePeriod: .milliseconds(200), pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20),
                promptSource: NoPassPromptSource()
            ).executeWrapped(
                identityFile: fixture.identityFile, endingFile: fixture.endingFile, timeout: .seconds(10),
                dispatchedAt: dispatchedAt,
                onSpawn: {
                    spawned.continuation.yield()
                    spawned.continuation.finish()
                }
            )
        }
        defer { shell.terminateAndReap() }
        for await _ in spawned.stream {}
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("wrapperdone")))
        let shellPID = try #require(fixture.pid(in: "shellpid"))
        let execution = await task.value
        #expect(execution.end == .exited(status: 0))
        #expect(!execution.snapshot.sessions.contains(getsid(shellPID)))
        #expect(!execution.snapshot.processGroups.contains(getpgrp()))

        let outcome = await ProcessFencer(
            pollInterval: .milliseconds(20), quiescenceTimeout: .seconds(1)
        ).fence(worktreePath: fixture.worktree.path, attributedTo: execution.snapshot)
        guard case .quiescent(let killed, let unattributed) = outcome else {
            Issue.record("expected attributed fence to reach quiescence, got \(outcome)")
            return
        }
        #expect(!killed.contains { $0.pid == shellPID })
        #expect(unattributed.contains { $0.pid == shellPID })
        #expect(shell.isRunning)
    }

    private func launchingShell(for fixture: RealPassWrapperFixture) throws -> SpawnedChild {
        let script = fixture.directory.appendingPathComponent("launch.sh")
        try #"""
            #!/bin/sh
            scratch="$1"
            shift
            echo $$ > "$scratch/shellpid"
            "$@"
            echo done > "$scratch/wrapperdone"
            exec /bin/sleep 60
            """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        return try SpawnedChild.spawn(
            executable: script.path,
            arguments: [fixture.directory.path, RealPassWrapperHarness.executable.path, fixture.cli.path,
                        fixture.identityFile.path, fixture.endingFile.path, fixture.signalFile.path,
                        fixture.stdoutFile.path, fixture.worktree.path, fixture.directory.path],
            currentDirectory: fixture.worktree
        )
    }

    @Test("timeout terminates a wrapped CLI and a descendant that escaped with setsid")
    func timeoutContainsEscapedDescendant() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: Self.escapedIgnoringTerm)
        defer { fixture.cleanUp() }
        _ = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("escaped")))
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("ready")))
        let escapedPID = try #require(fixture.pid(in: "escaped"))
        fixture.track(escapedPID)
        fixture.track(try #require(PassWrapperIdentity.read(from: fixture.identityFile)).cliPID)

        let execution = await monitor(fixture, timeout: .milliseconds(300), grace: .milliseconds(250))
        #expect(execution.end == .timedOut(after: .milliseconds(300), forcedKill: true))
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("term")))
        #expect(await awaitPassWrapperDead(escapedPID))
        #expect(await awaitPassWrapperDead(execution.pid))
    }

    @Test("task cancellation contains a wrapped process tree including a setsid child")
    func cancellationContainsEscapedDescendant() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: Self.escapedIgnoringTerm)
        defer { fixture.cleanUp() }
        _ = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("escaped")))
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("ready")))
        let identity = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
        let escapedPID = try #require(fixture.pid(in: "escaped"))
        fixture.track(identity.cliPID)
        fixture.track(escapedPID)
        let (task, spawned) = startMonitor(fixture, timeout: .seconds(30), grace: .milliseconds(250))
        for await _ in spawned {}
        #expect(kernelIdentity(identity.cliPID) != nil)
        task.cancel()
        let execution = await task.value

        #expect(execution.end == .aborted(forcedKill: true))
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("term")))
        #expect(await awaitPassWrapperDead(identity.cliPID))
        #expect(await awaitPassWrapperDead(escapedPID))
        #expect(execution.snapshot.processes.contains { $0.pid == escapedPID })
    }

    @Test("wrapper SIGKILL is wrapperLost and still contains the live escaped CLI tree")
    func wrapperLossContainsEscapedDescendant() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: Self.escapedIgnoringTerm)
        defer { fixture.cleanUp() }
        let wrapper = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("escaped")))
        let identity = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
        let escapedPID = try #require(fixture.pid(in: "escaped"))
        fixture.track(identity.cliPID)
        fixture.track(escapedPID)
        let (task, spawned) = startMonitor(fixture, timeout: .seconds(10), grace: .milliseconds(250))
        for await _ in spawned {}
        #expect(kill(wrapper.pid, SIGKILL) == 0)
        #expect(await wrapper.waitForExit() == .signalled(SIGKILL))

        let execution = await task.value
        #expect(execution.end == .wrapperLost)
        #expect(await awaitPassWrapperDead(identity.cliPID))
        #expect(await awaitPassWrapperDead(escapedPID))
    }

    @Test("missing and corrupt endings with a live descendant resolve to wrapperLost")
    func invalidEndingsResolveToWrapperLoss() async throws {
        for corrupt in [false, true] {
            let fixture = try RealPassWrapperHarness.makeFixture(script: Self.escapedIgnoringTerm)
            defer { fixture.cleanUp() }
            let wrapper = try fixture.launch()
            #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("ready")))
            #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("escaped")))
            let identity = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
            let escapedPID = try #require(fixture.pid(in: "escaped"))
            fixture.track(identity.cliPID)
            fixture.track(escapedPID)
            let barrier = FirstDrainBarrier()
            let (task, spawned) = startMonitor(
                fixture, timeout: .seconds(10), grace: .milliseconds(100),
                promptSource: FirstDrainBarrierSource(barrier: barrier)
            )
            for await _ in spawned {}
            await barrier.waitForFirstDrain()
            _ = kill(wrapper.pid, SIGKILL)
            _ = await wrapper.waitForExit()
            _ = kill(identity.cliPID, SIGKILL)
            if corrupt { try Data("exit 256\n".utf8).write(to: fixture.endingFile) }
            let execution = await task.value

            #expect(execution.end == .wrapperLost)
            #expect(PassWrapperEnding.read(from: fixture.endingFile) == nil)
            #expect(execution.snapshot.processes.contains { $0.pid == escapedPID })
            #expect(await awaitPassWrapperDead(escapedPID))
        }
    }

    @Test("prompt events for the actual wrapped CLI stop it promptly; unrelated PIDs are ignored")
    func wrappedPromptAttributionUsesRealPID() async throws {
        try await promptForWrappedCLI()
        try await promptForWrappedChild()
        try await unrelatedPromptIsIgnored()
    }

    private func promptForWrappedCLI() async throws {
        let fixture = try RealPassWrapperHarness.makeFixture(script: Self.readyThenSleep)
        defer { fixture.cleanUp() }
        _ = try fixture.launch()
        #expect(await awaitPassWrapperFile(fixture.directory.appendingPathComponent("ready")))
        let identity = try #require(PassWrapperIdentity.read(from: fixture.identityFile))
        fixture.track(identity.cliPID)
        let detail = "Keychain prompt for fixture CLI pid \(identity.cliPID)"
        let source = FixedPassPromptSource(event: PromptEvent(
            kind: .keychain, clientPID: identity.cliPID, detail: detail
        ))
        let execution = await AgentCLIProcess(
            gracePeriod: .milliseconds(200), pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20),
            promptSource: source
        ).executeWrapped(
            identityFile: fixture.identityFile, endingFile: fixture.endingFile, timeout: .seconds(10)
        )
        #expect(execution.end == .promptBlocked(detail: detail, forcedKill: false))
        #expect(await awaitPassWrapperDead(identity.cliPID))
    }

    private func promptForWrappedChild() async throws {
        let childFixture = try RealPassWrapperHarness.makeFixture(script: Self.sleepingChild)
        defer { childFixture.cleanUp() }
        _ = try childFixture.launch()
        #expect(await awaitPassWrapperFile(childFixture.directory.appendingPathComponent("child")))
        #expect(await awaitPassWrapperFile(childFixture.directory.appendingPathComponent("ready")))
        let childPID = try #require(childFixture.pid(in: "child"))
        childFixture.track(childPID)
        let childIdentity = try #require(PassWrapperIdentity.read(from: childFixture.identityFile))
        childFixture.track(childIdentity.cliPID)
        let childDetail = "Keychain prompt for wrapped child pid \(childPID)"
        let childExecution = await AgentCLIProcess(
            gracePeriod: .milliseconds(200), pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20),
            promptSource: FixedPassPromptSource(event: PromptEvent(
                kind: .keychain, clientPID: childPID, detail: childDetail
            ))
        ).executeWrapped(
            identityFile: childFixture.identityFile, endingFile: childFixture.endingFile, timeout: .seconds(10)
        )
        #expect(childExecution.end == .promptBlocked(detail: childDetail, forcedKill: false))
        #expect(await awaitPassWrapperDead(childPID))
    }

    private func unrelatedPromptIsIgnored() async throws {
        let unrelatedFixture = try RealPassWrapperHarness.makeFixture(script: "exit 0")
        defer { unrelatedFixture.cleanUp() }
        _ = try unrelatedFixture.launch()
        let unrelated = await AgentCLIProcess(
            gracePeriod: .milliseconds(100), pollInterval: .milliseconds(20),
            promptSource: FixedPassPromptSource(event: PromptEvent(
                kind: .keychain, clientPID: getpid(), detail: "unrelated prompt"
            ))
        ).executeWrapped(
            identityFile: unrelatedFixture.identityFile, endingFile: unrelatedFixture.endingFile, timeout: .seconds(5)
        )
        #expect(unrelated.end == .exited(status: 0))
    }

    private static let readyThenSleep = #"""
echo ready > "$1/ready"
exec /bin/sleep 60
"""#

    private static let escapedIgnoringTerm = #"""
if [ "${2:-}" = child ]; then
    trap '' TERM
    echo $$ > "$1/escaped"
    exec /bin/sleep 60
fi
/usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV' "$0" "$1" child &
echo ready > "$1/ready"
trap 'echo term > "$1/term"' TERM
while :; do /bin/sleep 60 & wait; done
"""#

    private static let sleepingChild = #"""
/bin/sleep 60 &
echo $! > "$1/child"
echo ready > "$1/ready"
wait
"""#

    private func monitor(
        _ fixture: RealPassWrapperFixture, timeout: Duration, grace: Duration = .milliseconds(250),
        dispatchedAt: ProcessStartTime? = nil
    ) async -> AgentCLIExecution {
        await AgentCLIProcess(
            gracePeriod: grace, pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20),
            promptSource: NoPassPromptSource()
        ).executeWrapped(
            identityFile: fixture.identityFile, endingFile: fixture.endingFile, timeout: timeout,
            dispatchedAt: dispatchedAt
        )
    }

    private func startMonitor(
        _ fixture: RealPassWrapperFixture, timeout: Duration, grace: Duration,
        dispatchedAt: ProcessStartTime? = nil, promptSource: any PromptSource = NoPassPromptSource()
    ) -> (Task<AgentCLIExecution, Never>, AsyncStream<Void>) {
        let spawned = makeSpawnStream()
        let task = Task {
            let execution = await AgentCLIProcess(
                gracePeriod: grace, pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20),
                promptSource: promptSource
            ).executeWrapped(
                identityFile: fixture.identityFile, endingFile: fixture.endingFile, timeout: timeout,
                dispatchedAt: dispatchedAt,
                onSpawn: {
                    spawned.continuation.yield()
                    spawned.continuation.finish()
                }
            )
            spawned.continuation.finish()
            return execution
        }
        return (task, spawned.stream)
    }

    private func awaitSignalCount(_ fixture: RealPassWrapperFixture, expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if PassWrapperSignalEvent.readAll(from: fixture.signalFile).count == expected { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return PassWrapperSignalEvent.readAll(from: fixture.signalFile).count == expected
    }
}

private func processStartTimeNow() -> ProcessStartTime {
    var timestamp = timeval()
    gettimeofday(&timestamp, nil)
    return ProcessStartTime(seconds: UInt64(timestamp.tv_sec), microseconds: UInt64(timestamp.tv_usec))
}

private struct SpawnStream {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation
}

private func makeSpawnStream() -> SpawnStream {
    let (stream, continuation) = AsyncStream<Void>.makeStream(of: Void.self)
    return SpawnStream(stream: stream, continuation: continuation)
}
private struct KernelIdentity {
    let start: (UInt64, UInt64)
    let group: pid_t
    let session: pid_t
}

private func kernelIdentity(_ pid: pid_t) -> KernelIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_status != UInt32(SZOMB) else { return nil }
    return KernelIdentity(
        start: (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec)),
        group: pid_t(bitPattern: info.pbi_pgid), session: getsid(pid)
    )
}
