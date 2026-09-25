import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

/// Exercises the running snapshot (Normal-Exit Sweep Ruling) a normal-exit run captures for the
/// attributed Worktree fence to consume (issue #175).
@Suite("Agent CLI running snapshot")
struct AgentCLIProcessRunningSnapshotTests {
    @Test("A normal exit's snapshot brackets its processes' start times and excludes the engine's own group/session")
    func normalExitSnapshotShape() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.leavesEscapedChildOnNormalExit)
        defer { fixture.cleanUp() }

        let runner = AgentCLIProcess(
            gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20)
        )
        let execution = try await runner.execute(fixture.launch(timeout: .seconds(5)))

        let childFile = fixture.scratch.appendingPathComponent("child")
        let childPID = try #require(StubAgentCLI.readPID(at: childFile))

        let snapshot = execution.snapshot
        // dispatchedAt was captured before the spawn, so it is <= every snapshotted process's start.
        for process in snapshot.processes {
            #expect(snapshot.dispatchedAt <= process.startTime)
        }
        #expect(snapshot.processes.contains { $0.pid == childPID })
        #expect(snapshot.processGroups.contains(execution.pid))

        #expect(!snapshot.processGroups.contains(getpgrp()))
        #expect(!snapshot.sessions.contains(getsid(0)))
    }
}
