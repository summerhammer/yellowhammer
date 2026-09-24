import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

/// Exercises the descendant sweep in `AgentCLIProcess+Termination.swift`: a real agent CLI's tool
/// commands routinely escape the CLI's process group (`setsid`, or a new group leader), and these
/// scenarios prove the escaped tool is still contained — on timeout, on engine abort, and even
/// when it is spawned only after the first SIGTERM has already gone out.
@Suite("Agent CLI process escape containment")
struct AgentCLIProcessEscapeTests {
    /// Polls (never sleeps a fixed duration) until `url` exists, or fails the test via `#require`.
    private static func awaitFile(_ url: URL, timeout: Duration = .seconds(2)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !FileManager.default.fileExists(atPath: url.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Polls until `pid` is dead, up to 500 ms — a generous bound for a process that has already
    /// been signalled by the time this is called.
    private static func awaitDead(_ pid: pid_t) async {
        for _ in 0..<25 {
            if StubAgentCLI.isDead(pid) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("Timeout, codex shape: the leader exits on TERM, but its escaped child is also contained")
    func timeoutCodexShapeContainsEscapedChild() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.leaderExitsOnTermLeavingEscapedChild)
        defer { fixture.cleanUp() }

        let timeout = Duration.seconds(2)
        let runner = AgentCLIProcess(gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20))
        let report = try await runner.run(fixture.launch(timeout: timeout))

        #expect(report.end == .timedOut(after: timeout, forcedKill: false))

        // Poll: the child may still be a zombie awaiting `launchd`'s reap, and `kill(pid, 0)` succeeds
        // on a zombie.
        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await Self.awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
    }

    @Test("Grace .zero: an escaped child that ignores TERM is contained by SIGKILL")
    func gracePeriodZeroForcesKillOfEscapedChild() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.escapedChildIgnoresTerm)
        defer { fixture.cleanUp() }

        let timeout = Duration.seconds(2)
        let runner = AgentCLIProcess(gracePeriod: .zero, pollInterval: .milliseconds(20))
        let report = try await runner.run(fixture.launch(timeout: timeout))

        #expect(report.end == .timedOut(after: timeout, forcedKill: true))

        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await Self.awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
    }

    @Test("Grace ~400ms: an escaped child that ignores TERM still needs, and gets, SIGKILL by identity")
    func gracePeriod400msForcesKillOfEscapedChild() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.escapedChildIgnoresTerm)
        defer { fixture.cleanUp() }

        let timeout = Duration.seconds(2)
        let runner = AgentCLIProcess(gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20))
        let report = try await runner.run(fixture.launch(timeout: timeout))

        #expect(report.end == .timedOut(after: timeout, forcedKill: true))

        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await Self.awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
    }

    @Test("Engine abort (Task cancellation) with an escaped child that ignores TERM contains it too")
    func engineAbortContainsEscapedChild() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.escapedChildIgnoresTerm)
        defer { fixture.cleanUp() }

        let runner = AgentCLIProcess(gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20))
        let launch = fixture.launch(timeout: .seconds(60))

        let task = Task { try await runner.run(launch) }
        // Poll for the escaped child's own pid file, not just the leader's "ready" marker: only
        // that confirms the child has actually finished `setsid` + re-exec and is fully visible
        // as a process, so the snapshot `terminate` takes right after cancelling is guaranteed to
        // find it.
        try await Self.awaitFile(fixture.scratch.appendingPathComponent("child"))
        task.cancel()
        let report = try await task.value

        #expect(report.end == .aborted(forcedKill: true))

        let childPID = try #require(StubAgentCLI.readPID(at: fixture.scratch.appendingPathComponent("child")))
        await Self.awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
    }

    @Test("A child spawned only from inside the leader's own SIGTERM handler is still found and contained")
    func childSpawnedDuringGraceWindowIsContained() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.spawnsEscapedChildOnTerm)
        defer { fixture.cleanUp() }

        let timeout = Duration.seconds(2)
        let runner = AgentCLIProcess(gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20))
        _ = try await runner.run(fixture.launch(timeout: timeout))

        let lateFile = fixture.scratch.appendingPathComponent("late")
        try await Self.awaitFile(lateFile, timeout: .seconds(1))
        let latePID = try #require(StubAgentCLI.readPID(at: lateFile))
        await Self.awaitDead(latePID)
        #expect(StubAgentCLI.isDead(latePID))
    }
}
