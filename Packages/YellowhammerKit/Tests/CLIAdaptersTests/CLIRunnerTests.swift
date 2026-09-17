import CLIAdapters
import Domain
import Foundation
import Testing

/// End-to-end through ``CLIRunner`` with stub `#!/bin/sh` executables standing in for `claude` and
/// `codex` — never the real CLIs. Each stub only ever talks over the argv/stdout/`-o` file contract
/// the corresponding adapter relies on, so these tests exercise the same path Yellowhammer takes in
/// production up to (not including) an actual vendor process.
@Suite("CLIRunner end to end, against stub CLIs")
struct CLIRunnerTests {
    private static let validWorkerStructuredOutput =
        """
        {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
        "commit":"0123456789abcdef0123456789abcdef01234567","summary":"stub ok"}
        """

    @Test("A stub claude that prints a valid structured_output completes, and returns its session")
    func stubClaudeCompletes() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let script = try Self.makeStubScript(
            in: fixture.tempDir,
            body: """
                printf '{"session_id":"stub-session","is_error":false,"structured_output":\(
                    Self.validWorkerStructuredOutput
                )}'
                exit 0
                """
        )
        let dispatch = fixture.dispatch(cli: "claude", executable: script.path)

        let report = try await CLIRunner().run(dispatch, adapter: ClaudeCodeAdapter())

        #expect(report.end == .exited(status: 0))
        #expect(report.session == CLISession(rawValue: "stub-session"))
        guard case .completed(.worker(let worker)) = report.outcome else {
            Issue.record("expected .completed(.worker(_)), got \(report.outcome)")
            return
        }
        #expect(worker.outcome == .completed(commit: "0123456789abcdef0123456789abcdef01234567", summary: "stub ok"))
    }

    @Test("A stub claude that exits 0 with is_error:true is Crashed-Unknown")
    func stubClaudeIsErrorIsCrashedUnknown() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let script = try Self.makeStubScript(
            in: fixture.tempDir,
            body: """
                printf '{"session_id":"stub-session","is_error":true,"structured_output":\(
                    Self.validWorkerStructuredOutput
                )}'
                exit 0
                """
        )
        let dispatch = fixture.dispatch(cli: "claude", executable: script.path)

        let report = try await CLIRunner().run(dispatch, adapter: ClaudeCodeAdapter())

        #expect(report.end == .exited(status: 0))
        guard case .crashedUnknown(.resultFile) = report.outcome else {
            Issue.record("expected .crashedUnknown(.resultFile(_)), got \(report.outcome)")
            return
        }
        // is_error still reports session_id — collect() reads it regardless of is_error.
        #expect(report.session == CLISession(rawValue: "stub-session"))
    }

    @Test("A stub codex that writes -o and prints thread.started completes, and returns its session")
    func stubCodexCompletes() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let script = try Self.makeStubScript(
            in: fixture.tempDir,
            body: """
                out=""
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = "-o" ]; then
                        out="$2"
                    fi
                    shift
                done
                printf '%s' '\(Self.validWorkerStructuredOutput)' > "$out"
                printf '{"type":"thread.started","thread_id":"stub-thread"}\\n'
                exit 0
                """
        )
        let dispatch = fixture.dispatch(cli: "codex", executable: script.path)

        let report = try await CLIRunner().run(dispatch, adapter: CodexAdapter())

        #expect(report.end == .exited(status: 0))
        #expect(report.session == CLISession(rawValue: "stub-thread"))
        guard case .completed(.worker(let worker)) = report.outcome else {
            Issue.record("expected .completed(.worker(_)), got \(report.outcome)")
            return
        }
        #expect(worker.outcome == .completed(commit: "0123456789abcdef0123456789abcdef01234567", summary: "stub ok"))
    }

    // MARK: - Helpers

    private static func makeStubScript(in tempDir: URL, body: String) throws -> URL {
        let scriptPath = tempDir.appendingPathComponent("cli-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }
}
