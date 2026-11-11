import Darwin
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC orca-unreachable; ADR-007 item 10; issue #799.
// When Orca cannot open a Work Card pass's tab (`WorkspaceError.unavailable`, which `runtime_unavailable` maps
// to), the pass runs by direct spawn with the same argv and session name, with no retry. From then on it is a
// direct spawn for every rule, external interruption included (ruling item 6).

@Suite("Orca unreachable: a Work Card pass runs unseen", .timeLimit(.minutes(1)))
struct OrcaTabFallbackTests {
    @Test("The fallback asks Orca once, runs the CLI with the pass's session name, and completes")
    func fallbackRunsOnceWithTheSameSessionName() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let argvFile = fixture.tempDir.appendingPathComponent("argv")
        let script = fixture.tempDir.appendingPathComponent("fake-claude-argv.sh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argvFile.path)"
        printf '{"type":"result","structured_output":{"schema":"yellowhammer.result.worker",\
        "version":1,"outcome":"completed","commit":"0123456789abcdef0123456789abcdef01234567",\
        "summary":"unseen pass done"},"session_id":"sess-unseen-1"}\\n'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)

        let workspace = FakeTabWorkspace(scriptedCreateError: .unavailable("Orca is not running"))
        let dispatch = try fixture.makeDispatch(workspace: workspace, scriptURL: script)
        let request = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-unseen", sessionName: "BACK-1 · worker · round 1"
        )

        let report = try await dispatch.dispatch(request)

        #expect(report.outcome.isCompleted)
        #expect(report.session == "sess-unseen-1")
        #expect(report.notShownInOrca == "Orca is not running")
        #expect(workspace.createAttempts == 1)
        #expect(workspace.createCalls.isEmpty)
        let argv = try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(argv.contains("BACK-1 · worker · round 1"))
    }

    @Test("An outside kill of a pass that fell back is a Route failure, never an external interruption")
    func fallbackPassKeepsDirectSpawnClassification() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        // Orca would read every tab as gone; a pass that never had a tab must not be judged by it.
        let workspace = FakeTabWorkspace(scriptedCreateError: .unavailable("Orca is not running"))
        workspace.scriptDefaultTerminalState(WorkspaceTerminalState(orphaned: true, processID: nil))
        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.exit143ScriptPath, timeout: .seconds(10)
        )
        let request = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-unseen-killed", sessionName: "unseen-killed-session"
        )

        let report = try await dispatch.dispatch(request)

        #expect(report.outcome == .failed(exitStatus: 143))
        let ending = try #require(AttemptEnding(failedRun: report.outcome))
        #expect(ending.excludesRoute)
        #expect(report.notShownInOrca == "Orca is not running")
        #expect(workspace.createAttempts == 1)
        #expect(workspace.closedHandles.isEmpty)
    }
}
