import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

/// Exercises the normal-exit sweep (Normal-Exit Sweep Ruling): when an agent CLI exits NORMALLY,
/// background tool processes it started (claude's Bash tool `setsid`s; codex makes tools group
/// leaders) are reparented to `launchd` at the leader's *exit* — not at its reap — so they can only
/// ever be found by a snapshot taken while the leader was still alive.
@Suite("Agent CLI normal-exit sweep")
struct AgentCLIProcessNormalExitSweepTests {
    /// Polls until `pid` is dead, up to 500 ms — a generous bound for a process that has already
    /// been signalled by the time this is called.
    private static func awaitDead(_ pid: pid_t) async {
        for _ in 0..<25 {
            if StubAgentCLI.isDead(pid) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("A normal exit sweeps and reports a background process the CLI leaves behind")
    func normalExitSweepsAndReportsEscapedChild() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.leavesEscapedChildOnNormalExit)
        defer { fixture.cleanUp() }

        let runner = AgentCLIProcess(
            gracePeriod: .milliseconds(400), pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20)
        )
        let report = try await runner.run(fixture.launch(timeout: .seconds(5)))

        #expect(report.end == .exited(status: 0))
        #expect(report.outcome.isCompleted)

        let childFile = fixture.scratch.appendingPathComponent("child")
        let childPID = try #require(StubAgentCLI.readPID(at: childFile))
        await Self.awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))

        #expect(report.leftovers.map(\.pid).contains(childPID))
        let leftover = try #require(report.leftovers.first { $0.pid == childPID })
        #expect(!leftover.commandName.isEmpty)
    }

    @Test("A normal-exit leftover that ignores SIGTERM is still contained, by SIGKILL")
    func normalExitEscalatesToKillForTermIgnoringChild() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.normalExitLeavesTermIgnoringChild)
        defer { fixture.cleanUp() }

        let runner = AgentCLIProcess(
            gracePeriod: .milliseconds(300), pollInterval: .milliseconds(20), snapshotInterval: .milliseconds(20)
        )
        let report = try await runner.run(fixture.launch(timeout: .seconds(5)))

        #expect(report.end == .exited(status: 0))

        let childFile = fixture.scratch.appendingPathComponent("child")
        let childPID = try #require(StubAgentCLI.readPID(at: childFile))
        await Self.awaitDead(childPID)
        #expect(StubAgentCLI.isDead(childPID))
        #expect(report.leftovers.map(\.pid).contains(childPID))
    }

    @Test("A clean exit with nothing left behind costs nothing: well under the default grace period")
    func cleanExitWithNothingToSweepIsZeroCost() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        let clock = ContinuousClock()
        let start = clock.now
        let report = try await AgentCLIProcess(snapshotInterval: .milliseconds(20)).run(fixture.launch())
        let elapsed = clock.now - start

        #expect(report.end == .exited(status: 0))
        #expect(report.leftovers.isEmpty)
        #expect(elapsed < .seconds(2))
    }
}

extension RunOutcome {
    fileprivate var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}
