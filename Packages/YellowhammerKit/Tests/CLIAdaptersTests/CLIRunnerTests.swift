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
            body: Self.claudeStreamBody(isError: false, structuredOutput: Self.validWorkerStructuredOutput)
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
            body: Self.claudeStreamBody(isError: true, structuredOutput: Self.validWorkerStructuredOutput)
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

    // MARK: - Prompt capture

    @Test("Prompt record is captured before the process starts, holds the instruction, and marks launched")
    func promptCaptureBeforeProcessStarts() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let recorder = FakePromptRecorder()
        let provenance = DispatchProvenance(
            recordID: "rec-order-test", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        let dispatch = fixture.dispatch(cli: "fake-cli", instruction: "exact instruction text", provenance: provenance)

        let adapter = SpyAdapter(recorder: recorder)
        let runner = CLIRunner(recorder: recorder)
        _ = try await runner.run(dispatch, adapter: adapter)

        let captured = try #require(adapter.capturedDuringLaunch)
        #expect(captured.id == "rec-order-test")
        #expect(captured.instruction == "exact instruction text")
        #expect(captured.outputSchema == "fake-schema-for-worker")
        #expect(captured.launch == .pending)
        #expect(adapter.launchesDuringLaunchCount == 0)

        #expect(recorder.launches.count == 1)
        #expect(recorder.launches.first?.launch == .launched)
        #expect(recorder.launches.first?.record.id == "rec-order-test")
    }

    @Test("A launch-build failure marks notLaunched with the error description")
    func launchBuildFailureMarksNotLaunched() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let recorder = FakePromptRecorder()
        let provenance = DispatchProvenance(
            recordID: "rec-fail-test", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        let dispatch = fixture.dispatch(cli: "fake-cli", provenance: provenance)
        let adapter = SpyAdapter(
            recorder: recorder,
            launchError: .unsupportedEffort(cli: "fake-cli", effort: "bogus", supported: ["high"])
        )

        let runner = CLIRunner(recorder: recorder)
        await #expect(throws: CLIAdapterError.self) {
            try await runner.run(dispatch, adapter: adapter)
        }

        #expect(recorder.captured.count == 1)
        #expect(recorder.launches.count == 1)
        let launch = try #require(recorder.launches.first?.launch)
        guard case .notLaunched(let cause) = launch else {
            Issue.record("expected .notLaunched, got \(launch)")
            return
        }
        #expect(cause.contains("does not support effort `bogus`"))
    }

    @Test("Resumed and new sessions are distinguished in the captured prompt record")
    func resumedAndNewSessionsDistinguished() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let recorder = FakePromptRecorder()
        let runner = CLIRunner(recorder: recorder)
        let adapter = SpyAdapter(recorder: recorder)

        let prov1 = DispatchProvenance(
            recordID: "rec-new", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        let newDispatch = fixture.dispatch(cli: "fake-cli", resume: nil, provenance: prov1)
        _ = try await runner.run(newDispatch, adapter: adapter)

        let prov2 = DispatchProvenance(
            recordID: "rec-resumed", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        let resumedDispatch = fixture.dispatch(
            cli: "fake-cli", resume: CLISession(rawValue: "prior-session-id"), provenance: prov2
        )
        _ = try await runner.run(resumedDispatch, adapter: adapter)

        #expect(recorder.captured.count == 2)
        #expect(recorder.captured[0].id == "rec-new")
        #expect(recorder.captured[0].session == .new)
        #expect(recorder.captured[1].id == "rec-resumed")
        #expect(recorder.captured[1].session == .resumed)
    }

    @Test("An unavailable recorder leaves the outcome unchanged")
    func unavailableRecorderLeavesOutcomeUnchanged() async throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let recorder = FakePromptRecorder()
        recorder.captureResult = .unavailable(cause: "disk full")
        let provenance = DispatchProvenance(
            recordID: "rec-unavail", family: .worker, projectID: "proj-1", runID: "run-1", nightID: 1
        )
        let dispatch = fixture.dispatch(cli: "fake-cli", provenance: provenance)
        let adapter = SpyAdapter(recorder: recorder)

        let report = try await CLIRunner(recorder: recorder).run(dispatch, adapter: adapter)
        #expect(report.end == .exited(status: 0))
    }

    // MARK: - Helpers

    private final class FakePromptRecorder: DispatchPromptRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _captured: [DispatchPromptRecord] = []
        private var _launches: [(launch: DispatchLaunch, record: DispatchPromptRecord)] = []
        var captureResult: DispatchPromptCapture = .recorded(id: "fake-id")

        var captured: [DispatchPromptRecord] {
            lock.lock()
            defer { lock.unlock() }
            return _captured
        }

        var launches: [(launch: DispatchLaunch, record: DispatchPromptRecord)] {
            lock.lock()
            defer { lock.unlock() }
            return _launches
        }

        func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture {
            lock.lock()
            _captured.append(record)
            lock.unlock()
            return captureResult
        }

        func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool {
            lock.lock()
            _launches.append((launch, record))
            lock.unlock()
            return true
        }
    }

    private final class SpyAdapter: CLIAdapter, @unchecked Sendable {
        let cli = "fake-cli"
        let adapterVersion = "1.0"
        let supportedEfforts = ["medium", "high"]
        var launchError: CLIAdapterError?
        let recorder: FakePromptRecorder
        var capturedDuringLaunch: DispatchPromptRecord?
        var launchesDuringLaunchCount = -1

        init(recorder: FakePromptRecorder, launchError: CLIAdapterError? = nil) {
            self.recorder = recorder
            self.launchError = launchError
        }

        func outputSchema(for pass: RunPass) -> String {
            "fake-schema-for-\(pass.rawValue)"
        }

        func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
            capturedDuringLaunch = recorder.captured.first
            launchesDuringLaunchCount = recorder.launches.count
            if let launchError {
                throw launchError
            }
            let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
            try? FileManager.default.createDirectory(at: dispatch.runDirectory, withIntermediateDirectories: true)
            return AgentCLILaunch(
                executable: dispatch.executable,
                arguments: [],
                environment: dispatch.environment,
                worktreePath: dispatch.worktreePath,
                resultFile: resultFile,
                pass: dispatch.pass,
                timeout: dispatch.timeout,
                outputLog: dispatch.runDirectory.appendingPathComponent("stderr.log"),
                standardOutput: dispatch.runDirectory.appendingPathComponent("stdout.log")
            )
        }

        func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession? { nil }
    }

    /// The body of a stub claude printing `stream-json` as `--output-format stream-json --verbose` does: a
    /// system init line, then one `result` event carrying the structured output.
    private static func claudeStreamBody(isError: Bool, structuredOutput: String) -> String {
        """
        printf '{"type":"system","subtype":"init","session_id":"stub-session"}\\n'
        printf '{"type":"result","subtype":"success","session_id":"stub-session",\
        "is_error":\(isError),"result_index":0,"structured_output":\(structuredOutput)}\\n'
        exit 0
        """
    }

    private static func makeStubScript(in tempDir: URL, body: String) throws -> URL {
        let scriptPath = tempDir.appendingPathComponent("cli-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath
    }
}
