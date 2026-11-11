import Domain
import Foundation
import OrcaADEAdapter
import Testing

/// Translations of Orca ADE 1.4.253's terminal contract that `OrcaTabHost` depends on (#795).
@Suite("OrcaADEAdapter terminal translation")
struct OrcaTerminalTranslationTests {
    private let handle = TerminalHandle(rawValue: "term_123")
    private let worktreeID = WorktreeID(rawValue: "repo-1::/abs/repo/feat")

    @Test("show reads an unknown handle as a terminal that is gone",
          arguments: ["terminal_handle_stale", "terminal_not_found"])
    func showUnknownHandle(code: String) async throws {
        let adapter = OrcaADEAdapter(runner: failure(code: code))

        await #expect(throws: WorkspaceError.terminalNotFound(handle)) {
            _ = try await adapter.terminal(handle)
        }
    }

    @Test("create and close keep an unknown-handle code as a vendor refusal", arguments: ["create", "close"])
    func unknownHandleOutsideShow(operation: String) async throws {
        let adapter = OrcaADEAdapter(runner: failure(code: "terminal_handle_stale"))

        await #expect(throws: WorkspaceError.refused(code: "terminal_handle_stale", message: "terminal_handle_stale")) {
            try await invoke(operation, adapter: adapter)
        }
    }

    @Test("a nonzero exit is never success, even with an ok envelope", arguments: ["create", "show", "close"])
    func nonzeroExitWithOKEnvelope(operation: String) async throws {
        let runner = StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(
                exitCode: 1,
                stdout: #"{"ok":true,"result":{"handle":"term_123","orphaned":false,"processId":4567}}"#,
                stderr: "failed"
            )
        ])
        let adapter = OrcaADEAdapter(runner: runner)

        do {
            try await invoke(operation, adapter: adapter)
            Issue.record("expected a throw")
        } catch {
            guard case .unavailable = error else {
                Issue.record("expected .unavailable, got \(error)")
                return
            }
        }
    }

    @Test("create refuses a session-leader pid that is not positive", arguments: [0, -1])
    func createNonPositivePID(pid: Int32) async throws {
        let adapter = OrcaADEAdapter(runner: success(#"{"terminal":{"handle":"term_123","processId":\#(pid)}}"#))

        do {
            _ = try await adapter.createTerminal(worktreeID: worktreeID, title: "worker", command: "true")
            Issue.record("expected a throw")
        } catch {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("show refuses a session-leader pid that is not positive", arguments: [0, -1])
    func showNonPositivePID(pid: Int32) async throws {
        let adapter = OrcaADEAdapter(
            runner: success(#"{"terminal":{"handle":"term_123","orphaned":false,"processId":\#(pid)}}"#)
        )

        do {
            _ = try await adapter.terminal(handle)
            Issue.record("expected a throw")
        } catch {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
        }
    }

    @Test("the probed 1.4.253 shape nests the terminal under result.terminal")
    func probedNestedShape() async throws {
        let created = try await OrcaADEAdapter(
            runner: success(#"{"terminal":{"handle":"term_123","processId":4567}}"#)
        ).createTerminal(worktreeID: worktreeID, title: "worker", command: "true")
        let shown = try await OrcaADEAdapter(
            runner: success(#"{"terminal":{"handle":"term_123","orphaned":true,"processId":4567}}"#)
        ).terminal(handle)

        #expect(created == WorkspaceTerminal(handle: handle, processID: 4567))
        #expect(shown == WorkspaceTerminalState(orphaned: true, processID: 4567))
    }

    private func success(_ result: String) -> StubOrcaCommandRunner {
        StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(exitCode: 0, stdout: #"{"ok":true,"result":\#(result)}"#, stderr: "")
        ])
    }

    private func failure(code: String) -> StubOrcaCommandRunner {
        StubOrcaCommandRunner(outputs: [
            OrcaCommandOutput(
                exitCode: 1,
                stdout: #"{"ok":false,"error":{"code":"\#(code)","message":"\#(code)"}}"#,
                stderr: ""
            )
        ])
    }

    private func invoke(_ operation: String, adapter: OrcaADEAdapter) async throws(WorkspaceError) {
        switch operation {
        case "create":
            _ = try await adapter.createTerminal(worktreeID: worktreeID, title: "worker", command: "true")
        case "show":
            _ = try await adapter.terminal(handle)
        default:
            try await adapter.closeTerminal(handle)
        }
    }
}
