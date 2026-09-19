import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

@Suite("Agent CLI process lifecycle")
struct AgentCLIProcessTests {

    @Test("Clean exit with a valid result file completes")
    func cleanExitCompletes() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        #expect(report.end == .exited(status: 0))
        #expect(report.processGroup == report.pid)
        guard case .completed(.worker(let worker)) = report.outcome else {
            Issue.record("expected .completed(.worker(_)), got \(report.outcome)")
            return
        }
        guard case .completed(let commit, let summary) = worker.outcome else {
            Issue.record("expected WorkerOutcome.completed, got \(worker.outcome)")
            return
        }
        #expect(commit == "0123456789abcdef0123456789abcdef01234567")
        #expect(summary == "stub")
    }

    @Test("Runs inside the Worktree, as the leader of its own process group")
    func runsInsideWorktreeInOwnProcessGroup() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.reportsWorktreeAndProcessGroup)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        #expect(report.outcome.isCompleted)

        let cwd = try String(contentsOf: fixture.scratch.appendingPathComponent("cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pgidText = try String(contentsOf: fixture.scratch.appendingPathComponent("pgid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pidText = try String(contentsOf: fixture.scratch.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(Self.realResolve(cwd) == Self.realResolve(fixture.worktree.path))
        #expect(pid_t(pgidText) == report.pid)
        #expect(pid_t(pidText) == report.pid)
        #expect(pid_t(pgidText) != getpgrp())
    }

    @Test("Stdin is closed, not left open to the CLI")
    func stdinIsClosed() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.reportsStdinState)
        defer { fixture.cleanUp() }

        _ = try await AgentCLIProcess().run(fixture.launch())

        let stdinState = try String(contentsOf: fixture.scratch.appendingPathComponent("stdin"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stdinState == "closed")
    }

    @Test("Exit 0 with an empty result file is Crashed-Unknown")
    func exitZeroEmptyFileIsCrashedUnknown() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.exitZeroEmptyFile)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        #expect(report.outcome == .crashedUnknown(.resultFile(.empty)))
    }

    @Test("Exit 0 with no result file is Crashed-Unknown")
    func exitZeroNoFileIsCrashedUnknown() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.exitZeroNoFile)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        guard case .crashedUnknown(.resultFile(.unreadable)) = report.outcome else {
            Issue.record("expected .crashedUnknown(.resultFile(.unreadable(_))), got \(report.outcome)")
            return
        }
    }

    @Test("Exit 0 with malformed JSON is Crashed-Unknown")
    func exitZeroMalformedFileIsCrashedUnknown() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.exitZeroMalformedFile)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        guard case .crashedUnknown(.resultFile(.malformedJSON)) = report.outcome else {
            Issue.record("expected .crashedUnknown(.resultFile(.malformedJSON(_))), got \(report.outcome)")
            return
        }
    }

    @Test("A non-zero exit is attributable to the CLI; the result file is not consulted")
    func nonZeroExitIsAttributableToCLI() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.nonZeroExitWithValidFile)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        #expect(report.outcome == .failed(exitStatus: 3))
        #expect(report.end == .exited(status: 3))
    }

    @Test("Killed by a foreign signal is Crashed-Unknown, not attributable to the CLI's exit")
    func killedByForeignSignalIsCrashedUnknown() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.killedByForeignSignal)
        defer { fixture.cleanUp() }

        let report = try await AgentCLIProcess().run(fixture.launch())

        #expect(report.end == .signaled(SIGKILL))
        #expect(report.outcome == .crashedUnknown(.signaled(SIGKILL)))
    }

    @Test("Timeout: SIGTERM honored by the leader, but an orphaned child is contained by SIGKILL")
    func timeoutLeaderHonorsTermOrphanContained() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.leaderHonorsTermButLeavesOrphan)
        defer { fixture.cleanUp() }

        // The timeout runs from the spawn, and the stub ignores SIGTERM only once `/bin/sh` has reached
        // its `trap`. With the whole target spawning at once that has taken over 300 ms, and the SIGTERM
        // then simply killed the stub; 2 s leaves the shell room to get there.
        let timeout = Duration.seconds(2)
        let runner = AgentCLIProcess(gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20))
        let report = try await runner.run(fixture.launch(timeout: timeout))

        #expect(report.end == .timedOut(after: timeout, forcedKill: true))
        #expect(report.outcome == .crashedUnknown(.terminated(report.end)))
        #expect(FileManager.default.fileExists(atPath: fixture.scratch.appendingPathComponent("term").path))

        let childFile = fixture.scratch.appendingPathComponent("child")
        let childPID = try #require(StubAgentCLI.readPID(at: childFile))

        var settled = false
        for _ in 0..<25 where !settled {
            if StubAgentCLI.isDead(childPID) {
                settled = true
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        #expect(settled)
    }

    @Test("Timeout: the whole group exits on SIGTERM, so SIGKILL is never needed")
    func timeoutWholeGroupExitsOnTerm() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.wholeGroupExitsOnTerm)
        defer { fixture.cleanUp() }

        let runner = AgentCLIProcess(gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20))
        let report = try await runner.run(fixture.launch(timeout: .milliseconds(300)))

        #expect(report.end == .timedOut(after: .milliseconds(300), forcedKill: false))
    }

    @Test("Timeout: SIGTERM ignored everywhere, escalates to SIGKILL, within the grace bound")
    func timeoutTermIgnoredEverywhereEscalatesToKill() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.groupIgnoresTermEverywhere)
        defer { fixture.cleanUp() }

        // 2 s, not a few hundred ms: the stub must reach its `trap` before the SIGTERM, see above.
        let timeout = Duration.seconds(2)
        let gracePeriod = Duration.milliseconds(400)
        let runner = AgentCLIProcess(gracePeriod: gracePeriod, pollInterval: .milliseconds(20))

        let clock = ContinuousClock()
        let start = clock.now
        let report = try await runner.run(fixture.launch(timeout: timeout))
        let elapsed = clock.now - start

        #expect(report.end == .timedOut(after: timeout, forcedKill: true))
        // Upper bound proving the grace window is honored, not skipped: timeout + grace + slack.
        #expect(elapsed < timeout + gracePeriod + .seconds(2))
        #expect(StubAgentCLI.isDead(report.pid))

        let childFile = fixture.scratch.appendingPathComponent("child")
        if let childPID = StubAgentCLI.readPID(at: childFile) {
            #expect(StubAgentCLI.isDead(childPID))
        }
    }

    @Test("Engine abort (Task cancellation) ends the run without a forced kill")
    func engineAbortEndsRun() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.wholeGroupExitsOnTerm)
        defer { fixture.cleanUp() }

        let runner = AgentCLIProcess(gracePeriod: .milliseconds(500), pollInterval: .milliseconds(20))
        let launch = fixture.launch(timeout: .seconds(60))

        let task = Task { try await runner.run(launch) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let report = try await task.value

        #expect(report.end == .aborted(forcedKill: false))
        #expect(report.outcome == .crashedUnknown(.terminated(.aborted(forcedKill: false))))
    }

    @Test("Default grace period is 3 seconds")
    func defaultGracePeriodIsThreeSeconds() {
        #expect(AgentCLIProcess().gracePeriod == .seconds(3))
    }

    @Test("A missing Worktree throws before spawning")
    func missingWorktreeThrows() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.worktree)

        await #expect(throws: AgentCLILaunchError.worktreeMissing(fixture.worktree.path)) {
            _ = try await AgentCLIProcess().run(fixture.launch())
        }
    }

    @Test("A missing executable fails to spawn")
    func missingExecutableFailsToSpawn() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }
        var launch = fixture.launch()
        launch.executable = fixture.tempDir.appendingPathComponent("does-not-exist").path

        do {
            _ = try await AgentCLIProcess().run(launch)
            Issue.record("expected .spawnFailed")
        } catch let error as AgentCLILaunchError {
            guard case .spawnFailed(let errorCode, _) = error else {
                Issue.record("expected .spawnFailed, got \(error)")
                return
            }
            #expect(errorCode == ENOENT)
        }
    }

    @Test("Output log captures both stdout and stderr")
    func outputLogCapturesStdoutAndStderr() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.writesStdoutAndStderr)
        defer { fixture.cleanUp() }
        let outputLog = fixture.tempDir.appendingPathComponent("output.log")

        _ = try await AgentCLIProcess().run(fixture.launch(outputLog: outputLog))

        let logContents = try String(contentsOf: outputLog, encoding: .utf8)
        #expect(logContents.contains("out"))
        #expect(logContents.contains("err"))
    }

    @Test("standardOutput, when set, receives stdout only; outputLog receives stderr only")
    func standardOutputSplitsStdoutFromStderr() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.writesStdoutAndStderr)
        defer { fixture.cleanUp() }
        let outputLog = fixture.tempDir.appendingPathComponent("stderr.log")
        let standardOutput = fixture.tempDir.appendingPathComponent("stdout.log")

        _ = try await AgentCLIProcess().run(fixture.launch(outputLog: outputLog, standardOutput: standardOutput))

        let stdoutContents = try String(contentsOf: standardOutput, encoding: .utf8)
        let stderrContents = try String(contentsOf: outputLog, encoding: .utf8)
        #expect(stdoutContents.contains("out"))
        #expect(!stdoutContents.contains("err"))
        #expect(stderrContents.contains("err"))
        #expect(!stderrContents.contains("out"))
    }

    // MARK: - Helpers

    private static func realResolve(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buffer) else { return path }
        return String(cString: resolved)
    }
}

extension RunOutcome {
    fileprivate var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}
