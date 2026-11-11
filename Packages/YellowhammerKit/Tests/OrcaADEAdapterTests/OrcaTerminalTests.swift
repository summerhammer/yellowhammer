import Domain
import OrcaADEAdapter
import Testing

@Suite("Orca ADE terminal operations")
struct OrcaTerminalTests {
    private let worktreeID = WorktreeID(rawValue: "repo::/repo/worktree")
    private let handle = TerminalHandle(rawValue: "term_123")

    @Test("create preserves title and command as single argv values and returns the session leader")
    func create() async throws {
        let runner = runner(#"{"terminal":{"handle":"term_123","processId":8716},"extra":"ignored"}"#)
        let terminal = try await OrcaADEAdapter(runner: runner).createTerminal(
            worktreeID: worktreeID, title: "YH · worker · Round 2", command: "bash '/tmp/my launcher.sh'"
        )
        #expect(terminal == WorkspaceTerminal(handle: handle, sessionLeaderPID: 8716))
        #expect(runner.calls == [[
            "terminal", "create", "--worktree", "id:repo::/repo/worktree", "--title", "YH · worker · Round 2",
            "--command", "bash '/tmp/my launcher.sh'", "--json"
        ]])
    }

    @Test("show distinguishes live and orphaned terminals", arguments: [false, true])
    func show(orphaned: Bool) async throws {
        let runner = runner("{\"terminal\":{\"handle\":\"term_123\",\"orphaned\":\(orphaned),\"processId\":8716}}")
        let state = try await OrcaADEAdapter(runner: runner).showTerminal(handle: handle)
        #expect(state == WorkspaceTerminalState(orphaned: orphaned, sessionLeaderPID: 8716))
        #expect(runner.calls == [["terminal", "show", "--terminal", "term_123", "--json"]])
    }

    @Test("show tolerates a runtime that omits the session leader", arguments: [
        #"{"terminal":{"handle":"term_123","orphaned":true}}"#,
        #"{"terminal":{"handle":"term_123","orphaned":true,"processId":null}}"#
    ])
    func showWithoutPID(result: String) async throws {
        let runner = runner(result)
        #expect(try await OrcaADEAdapter(runner: runner).showTerminal(handle: handle) ==
            WorkspaceTerminalState(orphaned: true, sessionLeaderPID: nil))
    }

    @Test("unknown terminal handles are gone", arguments: ["terminal_handle_stale", "terminal_not_found"])
    func unknownHandle(code: String) async throws {
        let runner = failure(code: code)
        #expect(try await OrcaADEAdapter(runner: runner).showTerminal(handle: handle) == nil)
        #expect(runner.calls.count == 1)
    }

    @Test("close removes only one tab, even when Orca reports ptyKilled false")
    func close() async throws {
        let runner = runner(#"{"close":{"handle":"term_123","ptyKilled":false,"tabClosed":true}}"#)
        try await OrcaADEAdapter(runner: runner).closeTerminal(handle: handle)
        #expect(runner.calls == [["terminal", "close", "--terminal", "term_123", "--tab", "--json"]])
    }

    @Test("runtime unavailability is reported once without retry", arguments: ["create", "show", "close", "list"])
    func unavailable(operation: String) async throws {
        let runner = failure(code: "runtime_unavailable")
        await #expect(throws: WorkspaceError.unavailable("runtime_unavailable")) {
            try await invoke(operation, adapter: OrcaADEAdapter(runner: runner))
        }
        #expect(runner.calls.count == 1)
    }

    @Test("other refusals retain their vendor code", arguments: ["create", "show", "close"])
    func refusal(operation: String) async throws {
        let runner = failure(code: "permission_denied")
        await #expect(throws: WorkspaceError.refused(code: "permission_denied", message: "permission_denied")) {
            try await invoke(operation, adapter: OrcaADEAdapter(runner: runner))
        }
        #expect(runner.calls.count == 1)
    }

    @Test("only show translates an unknown handle to gone", arguments: ["create", "close"])
    func unknownOutsideShow(operation: String) async throws {
        let runner = failure(code: "terminal_handle_stale")
        await #expect(throws: WorkspaceError.refused(code: "terminal_handle_stale", message: "terminal_handle_stale")) {
            try await invoke(operation, adapter: OrcaADEAdapter(runner: runner))
        }
    }

    @Test("create refuses missing or invalid handle and pid", arguments: [
        #"{"terminal":{"handle":"term_123"}}"#,
        #"{"terminal":{"handle":"","processId":8716}}"#,
        #"{"terminal":{"handle":"term_123","processId":0}}"#,
        #"{"terminal":{"handle":"term_123","processId":-1}}"#,
        #"{"terminal":{"handle":"term_123","processId":2147483648}}"#
    ])
    func malformedCreate(result: String) async throws {
        let adapter = OrcaADEAdapter(runner: runner(result))
        await #expect(throws: WorkspaceError.self) {
            _ = try await adapter.createTerminal(worktreeID: worktreeID, title: "title", command: "bash launcher")
        }
    }

    @Test("show refuses missing orphaned metadata")
    func malformedShow() async throws {
        let adapter = OrcaADEAdapter(runner: runner(#"{"terminal":{"handle":"term_123","processId":8716}}"#))
        await #expect(throws: WorkspaceError.self) { _ = try await adapter.showTerminal(handle: handle) }
    }

    @Test("a nonzero exit is never success even with an ok envelope")
    func nonzeroSuccess() async throws {
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 1, stdout: #"{"ok":true,"result":{}}"#, stderr: "failed")
        ])
        await #expect(throws: WorkspaceError.self) {
            try await OrcaADEAdapter(runner: runner).closeTerminal(handle: handle)
        }
        #expect(runner.calls.count == 1)
    }

    @Test("non-JSON failures surface as unavailable", arguments: ["create", "show", "close"])
    func nonJSONFailure(operation: String) async throws {
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 1, stdout: "", stderr: "cannot reach runtime")
        ])
        await #expect(throws: WorkspaceError.unavailable("orca exited 1: cannot reach runtime")) {
            try await invoke(operation, adapter: OrcaADEAdapter(runner: runner))
        }
        #expect(runner.calls.count == 1)
    }

    @Test("launch failures surface as unavailable", arguments: ["create", "show", "close"])
    func launchFailure(operation: String) async throws {
        do {
            try await invoke(operation, adapter: OrcaADEAdapter(runner: UnlaunchableOrcaRunner()))
            Issue.record("expected launch failure")
        } catch {
            guard case .unavailable = error else {
                Issue.record("expected unavailable, received \(error)")
                return
            }
        }
    }

    private func runner(_ result: String) -> StubOrcaCommandRunner {
        StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 0, stdout: "{\"ok\":true,\"result\":\(result)}", stderr: "")
        ])
    }

    private func failure(code: String) -> StubOrcaCommandRunner {
        StubOrcaCommandRunner(outputs: [OrcaCommandOutput(
            exitCode: 1, stdout: "{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"\(code)\"}}", stderr: ""
        )])
    }

    private func invoke(_ operation: String, adapter: OrcaADEAdapter) async throws(WorkspaceError) {
        switch operation {
        case "create":
            _ = try await adapter.createTerminal(worktreeID: worktreeID, title: "title", command: "bash launcher")
        case "show":
            _ = try await adapter.showTerminal(handle: handle)
        case "list":
            _ = try await adapter.registeredRepositoryPaths()
        default:
            try await adapter.closeTerminal(handle: handle)
        }
    }
}

private struct UnlaunchableOrcaRunner: OrcaCommandRunner {
    private enum LaunchError: Error { case missingExecutable }

    func run(_ arguments: [String]) async throws -> OrcaCommandOutput {
        throw LaunchError.missingExecutable
    }
}
