import Darwin
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("Orca tab interruption evidence", .timeLimit(.minutes(1)))
struct OrcaTabInterruptionEvidenceTests {
    private struct DispatchObservation {
        let fixture: OrcaTabPassFixture
        let workspace: FakeTabWorkspace
        let report: AgentDispatchReport
    }

    @Test("Orphaned tab and exit 143 become external interruption")
    func orphanedTabAndExit143() async throws {
        let observation = try await dispatch143(with: .orphaned)
        defer { observation.fixture.cleanUp() }

        #expect(isExternalInterruption(observation.report.outcome))
        #expect(observation.report.tabInterruption == TabInterruptionEvidence(tabState: .orphaned, loginState: .alive))
        #expect(observation.workspace.observedBeforeClose[TerminalHandle(rawValue: "tab-1")] == true)
        let ending = try #require(AttemptEnding(failedRun: observation.report.outcome))
        #expect(ending.consumesAttempt)
        #expect(!ending.excludesRoute)
    }

    @Test("Orca terminalNotFound and exit 143 become external interruption")
    func missingTerminalAndExit143() async throws {
        let observation = try await dispatch143(with: .missing)
        defer { observation.fixture.cleanUp() }

        #expect(isExternalInterruption(observation.report.outcome))
        #expect(observation.report.tabInterruption?.tabState == .missing)
        #expect(observation.workspace.observedBeforeClose[TerminalHandle(rawValue: "tab-1")] == true)
    }

    @Test("An unavailable terminal query while the login is alive preserves exit 143")
    func unavailableQueryPreservesExitStatus() async throws {
        let observation = try await dispatch143(with: .unavailable)
        defer { observation.fixture.cleanUp() }

        #expect(observation.report.outcome == .failed(exitStatus: 143))
        #expect(observation.report.tabInterruption?.tabState == .unavailable)
        #expect(observation.report.tabInterruption?.loginState == .alive)
        #expect(observation.workspace.observedBeforeClose[TerminalHandle(rawValue: "tab-1")] == true)
        let ending = try #require(AttemptEnding(failedRun: observation.report.outcome))
        #expect(ending.excludesRoute)
        #expect(ending.consumesAttempt)
    }

    @Test("A tab reporting PID zero has unknown login state and preserves exit 143")
    func zeroPIDDoesNotProveInterruption() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }
        let workspace = FakeTabWorkspace()
        workspace.scriptProcessID(0)
        let dispatch = try fixture.makeDispatch(workspace: workspace, scriptURL: fixture.exit143ScriptPath)
        let report = try await dispatch.dispatch(fixture.makeRequest(worktreeID: "wt-zero-pid"))

        #expect(report.outcome == .failed(exitStatus: 143))
        #expect(report.tabInterruption == TabInterruptionEvidence(tabState: .present, loginState: .unknown))
    }

    @Test("An engine abort remains Crashed-Unknown when Orca reports an orphaned tab")
    func engineAbortWithOrphanedTab() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }
        let workspace = FakeTabWorkspace()
        workspace.scriptDefaultTerminalState(WorkspaceTerminalState(orphaned: true))
        let ready = fixture.tempDir.appendingPathComponent("abort-ready")
        let script = try writeScript(
            fixture,
            name: "wait-until-aborted.sh",
            body: "trap '' TERM\ntouch \"\(ready.path)\"\nwhile :; do sleep 1; done\n"
        )
        let dispatch = try fixture.makeDispatch(workspace: workspace, scriptURL: script, timeout: .seconds(30))
        let request = fixture.makeRequest(worktreeID: "wt-abort")
        let task = Task {
            try await dispatch.dispatch(request)
        }
        defer { task.cancel() }
        try await waitForFile(ready)
        task.cancel()
        let report = try await task.value

        #expect(report.outcome == .crashedUnknown(.terminated(.aborted(forcedKill: true))))
        #expect(report.engineSignalled)
        #expect(report.tabInterruption?.tabState == .orphaned)
        #expect(workspace.observedBeforeClose[TerminalHandle(rawValue: "tab-1")] == true)
    }

    private enum TabStateSetup {
        case orphaned
        case missing
        case unavailable
    }

    private func dispatch143(
        with setup: TabStateSetup
    ) async throws -> DispatchObservation {
        let fixture = try OrcaTabPassFixture()
        let workspace = FakeTabWorkspace()
        let handle = TerminalHandle(rawValue: "tab-1")
        switch setup {
        case .orphaned:
            workspace.scriptDefaultTerminalState(WorkspaceTerminalState(orphaned: true))
        case .missing:
            workspace.scriptTerminalError(handle, .terminalNotFound(handle))
        case .unavailable:
            workspace.scriptTerminalError(handle, .unavailable("terminal query unavailable"))
        }
        let dispatch = try fixture.makeDispatch(workspace: workspace, scriptURL: fixture.exit143ScriptPath)
        let report = try await dispatch.dispatch(fixture.makeRequest(worktreeID: "wt-evidence"))
        return DispatchObservation(fixture: fixture, workspace: workspace, report: report)
    }

    private func isExternalInterruption(_ outcome: RunOutcome) -> Bool {
        guard case .crashedUnknown(.externalInterruption) = outcome else { return false }
        return true
    }

    private func writeScript(_ fixture: OrcaTabPassFixture, name: String, body: String) throws -> URL {
        let url = fixture.tempDir.appendingPathComponent(name)
        try ("#!/bin/bash\nset +e\n" + body).write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o755) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(url.lastPathComponent)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
