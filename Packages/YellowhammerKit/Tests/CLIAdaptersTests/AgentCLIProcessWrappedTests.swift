import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

@Suite("Agent CLI wrapped process supervision", .timeLimit(.minutes(1)))
struct AgentCLIProcessWrappedTests {
    @Test("Clean exit: supervised by identity and RunEnd comes from wrapper-status.json")
    func cleanExitSupervisedByIdentity() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let process = AgentCLIProcess(wrapperExecutable: wrapperURL.path)
        let report = try await process.runWrapped(fixture.launch(), runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        #expect(report.end == .exited(status: 0))
        #expect(report.outcome.isWrappedCompleted)
        #expect(report.engineSignalled == false)
        #expect(report.pid > 0)
        #expect(report.receivedSignals.isEmpty)

        // Read wrapper-started.json directly to check identity matches
        let startedURL = fixture.tempDir.appendingPathComponent(PassWrapper.startedFileName)
        let data = try Data(contentsOf: startedURL)
        let started = try JSONDecoder().decode(PassWrapperStarted.self, from: data)
        #expect(report.pid == started.pid)
    }

    @Test("Non-zero exit: maps to failed outcome and reports engineSignalled false")
    func nonZeroExitAttributableToCLI() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.nonZeroExitWithValidFile)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let process = AgentCLIProcess(wrapperExecutable: wrapperURL.path)
        let report = try await process.runWrapped(fixture.launch(), runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        #expect(report.end == .exited(status: 3))
        #expect(report.outcome == .failed(exitStatus: 3))
        #expect(report.engineSignalled == false)
        #expect(report.pid > 0)
    }

    @Test("SIGTERM-grace and SIGKILL containment of a tool that escaped into its own session")
    func timeoutContainsEscapedChild() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.escapedChildIgnoresTerm)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let timeout = Duration.seconds(4)
        let process = AgentCLIProcess(
            gracePeriod: .milliseconds(400),
            pollInterval: .milliseconds(20),
            wrapperExecutable: wrapperURL.path
        )
        let launch = fixture.launch(timeout: timeout)
        let report = try await process.runWrapped(launch, runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        #expect(report.end == .timedOut(after: timeout, forcedKill: true))
        #expect(report.engineSignalled == true)

        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
    }

    @Test("Abort: Task cancellation contains tool and reports engineSignalled true")
    func abortContainsEscapedChild() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.escapedChildIgnoresTerm)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let process = AgentCLIProcess(
            gracePeriod: .milliseconds(200),
            pollInterval: .milliseconds(20),
            wrapperExecutable: wrapperURL.path
        )
        let launch = fixture.launch(timeout: .seconds(60))

        let task = Task {
            try await process.runWrapped(launch, runDirectory: fixture.tempDir) { launcherURL in
                let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
                tracker.add(pid)
            }
        }

        try await awaitFile(fixture.scratch.appendingPathComponent("child"))
        task.cancel()
        let report = try await task.value

        #expect(report.end == .aborted(forcedKill: true))
        #expect(report.engineSignalled == true)

        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
    }

    @Test("Timeout: group exiting on TERM ends without forced kill and reports engineSignalled true")
    func timeoutEndsWithoutForcedKill() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.wholeGroupExitsOnTerm)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let timeout = Duration.seconds(2)
        let process = AgentCLIProcess(
            gracePeriod: .milliseconds(400),
            pollInterval: .milliseconds(20),
            wrapperExecutable: wrapperURL.path
        )
        let launch = fixture.launch(timeout: timeout)
        let report = try await process.runWrapped(launch, runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        #expect(report.end == .timedOut(after: timeout, forcedKill: false))
        #expect(report.engineSignalled == true)
    }

    @Test("Normal-exit sweep of a detached background process sweeps and reports leftovers")
    func normalExitSweepsBackgroundProcess() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.leavesEscapedChildOnNormalExit)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let process = AgentCLIProcess(
            gracePeriod: .milliseconds(400),
            pollInterval: .milliseconds(20),
            snapshotInterval: .milliseconds(20),
            wrapperExecutable: wrapperURL.path
        )
        let launch = fixture.launch(timeout: .seconds(5))
        let report = try await process.runWrapped(launch, runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        #expect(report.end == .exited(status: 0))
        #expect(report.outcome.isWrappedCompleted)
        #expect(report.engineSignalled == false)

        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))

        #expect(report.leftovers.count == 1)
        #expect(report.leftovers.first?.pid == childPID)
    }

    @Test("Stand-in login, shell and wrapper are absent from the snapshot and still alive")
    func tabProcessesAbsentFromSnapshot() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let process = AgentCLIProcess(wrapperExecutable: wrapperURL.path)
        let report = try await process.runWrapped(fixture.launch(), runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        let shellPID = try #require(tracker.first)
        #expect(report.end == .exited(status: 0))
        #expect(shellPID > 0)

        // Verify shellPID is NOT in the snapshot
        let snapshotPIDs = report.snapshot.processes.map(\.pid)
        #expect(!snapshotPIDs.contains(shellPID))

        let shellPGID = getpgid(shellPID)
        #expect(!report.snapshot.processGroups.contains(shellPGID))

        let shellSID = getsid(shellPID)
        #expect(!report.snapshot.sessions.contains(shellSID))

        // And the shell process is still alive after the pass
        #expect(kill(shellPID, 0) == 0)
    }

    @Test("Status record deleted before read ends Crashed-Unknown with host crash block reason")
    func statusRecordMissingEndsCrashedUnknown() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        // A wrapper executable script that runs PassWrapperChild with an altered status path that is deleted
        let wrapperScript = fixture.tempDir.appendingPathComponent("wrapper_deleter.sh")
        let scriptContent = """
        #!/bin/bash
        sed -i '' 's/wrapper-status\\.json/wrapper-status-deleted\\.json/' "$2"
        "\(wrapperURL.path)" "$1" "$2"
        rm -f "$(dirname "$2")/wrapper-status-deleted.json"
        """
        try scriptContent.write(to: wrapperScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperScript.path)

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let process = AgentCLIProcess(
            statusTimeout: .milliseconds(50),
            wrapperExecutable: wrapperScript.path
        )
        let report = try await process.runWrapped(fixture.launch(), runDirectory: fixture.tempDir) { launcherURL in
            let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
            tracker.add(pid)
        }

        guard case .crashedUnknown(let cause) = report.end else {
            Issue.record("expected .crashedUnknown end, got \(report.end)")
            return
        }
        guard case .wrapperRecordMissing = cause else {
            Issue.record("expected .wrapperRecordMissing cause, got \(cause)")
            return
        }
        #expect(report.outcome == .crashedUnknown(cause))

        let ending = try #require(AttemptEnding(failedRun: report.outcome))
        #expect(ending.outcome == .crashedUnknown)
        #expect(ending.consumedHow == "consumed; route not excluded (Crashed-Unknown)")
        #expect(!ending.classification.hasPrefix(AttemptEnding.engineStoppedClassificationPrefix))
        #expect(ending.excludesRoute == false)
        #expect(ending.consumesAttempt == true)
    }

    @Test("Wrapper that never starts the CLI ends Crashed-Unknown")
    func wrapperNeverStartsEndsCrashedUnknown() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        let process = AgentCLIProcess(
            startTimeout: .milliseconds(50)
        )
        let report = try await process.runWrapped(fixture.launch(), runDirectory: fixture.tempDir) { _ in
            // Does not start the wrapper
        }

        guard case .crashedUnknown(let cause) = report.end else {
            Issue.record("expected .crashedUnknown end, got \(report.end)")
            return
        }
        guard case .wrapperRecordMissing = cause else {
            Issue.record("expected .wrapperRecordMissing cause, got \(cause)")
            return
        }
        #expect(report.outcome == .crashedUnknown(cause))

        let ending = try #require(AttemptEnding(failedRun: report.outcome))
        #expect(ending.outcome == .crashedUnknown)
        #expect(ending.consumedHow == "consumed; route not excluded (Crashed-Unknown)")
        #expect(!ending.classification.hasPrefix(AttemptEnding.engineStoppedClassificationPrefix))
    }
}
