@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("ClaudeCodeAdapter")
struct ClaudeCodeAdapterTests {
    private let adapter = ClaudeCodeAdapter()

    // MARK: - argv shape

    @Test("First dispatch, worker: forces schema, picks a fresh session id, acceptEdits permissions")
    func firstDispatchWorkerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude", model: "haiku", effort: "high", pass: .worker)

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(args[0] == "-p")
        #expect(args[1] == dispatch.instruction)
        #expect(Self.value(after: "--output-format", in: args) == "json")
        #expect(Self.value(after: "--json-schema", in: args) == CLIOutputSchema.strict(for: .worker))
        #expect(Self.value(after: "--model", in: args) == "haiku")
        #expect(Self.value(after: "--effort", in: args) == "high")
        #expect(!args.contains("--resume"))
        let sessionID = try #require(Self.value(after: "--session-id", in: args))
        #expect(UUID(uuidString: sessionID) != nil)
        #expect(sessionID == sessionID.lowercased())
        #expect(Self.value(after: "--permission-mode", in: args) == "acceptEdits")
        #expect(Self.value(after: "--allowedTools", in: args) == "Bash Edit Write Read Glob Grep")
        #expect(!args.contains("--disallowedTools"))
    }

    @Test("Round, worker: replaces --session-id with --resume, everything else the same")
    func roundWorkerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let session = CLISession(rawValue: "prior-session")
        let dispatch = fixture.dispatch(
            cli: "claude", model: "haiku", effort: "high", pass: .worker, resume: session
        )

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(!args.contains("--session-id"))
        #expect(Self.value(after: "--resume", in: args) == "prior-session")
        #expect(Self.value(after: "--model", in: args) == "haiku")
        #expect(Self.value(after: "--effort", in: args) == "high")
        #expect(Self.value(after: "--permission-mode", in: args) == "acceptEdits")
        #expect(Self.value(after: "--allowedTools", in: args) == "Bash Edit Write Read Glob Grep")
    }

    @Test("First dispatch, reviewer: dontAsk, narrow allowed tools, Edit/Write/NotebookEdit denied")
    func firstDispatchReviewerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude", pass: .reviewer)

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(Self.value(after: "--json-schema", in: args) == CLIOutputSchema.strict(for: .reviewer))
        #expect(Self.value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(Self.value(after: "--allowedTools", in: args) == "Bash Read Glob Grep")
        #expect(Self.value(after: "--disallowedTools", in: args) == "Edit Write NotebookEdit")
    }

    @Test("Architect pass gets the same dontAsk permissions as reviewer")
    func architectPermissions() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude", pass: .architect)

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(Self.value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(Self.value(after: "--json-schema", in: args) == CLIOutputSchema.strict(for: .architect))
    }

    @Test("Additional writable directories become repeated --add-dir flags")
    func addDirFlags() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "claude", additionalWritableDirectories: ["/a/gitdir", "/b/gitdir"]
        )

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(Self.indices(of: "--add-dir", in: args).count == 2)
        #expect(Self.value(after: "--add-dir", in: args) == "/a/gitdir")
    }

    // MARK: - Refusals

    @Test("A Route for another CLI is refused")
    func wrongCLIRefused() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex")

        #expect(throws: CLIAdapterError.routeForOtherCLI(expected: "claude", got: "codex")) {
            try adapter.launch(for: dispatch)
        }
    }

    @Test("An unsupported effort is refused")
    func unsupportedEffortRefused() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude", effort: "ultra")

        #expect(throws: CLIAdapterError.unsupportedEffort(
            cli: "claude", effort: "ultra", supported: adapter.supportedEfforts
        )) {
            try adapter.launch(for: dispatch)
        }
    }

    // MARK: - Stale result file

    @Test("A stale result.json in runDirectory is removed before launch")
    func staleResultFileRemoved() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.runDirectory, withIntermediateDirectories: true)
        let resultFile = fixture.runDirectory.appendingPathComponent("result.json")
        try Data("stale".utf8).write(to: resultFile)

        _ = try adapter.launch(for: fixture.dispatch(cli: "claude"))

        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
    }

    // MARK: - collect

    @Test("collect: valid structured_output materializes result.json and reads session_id")
    func collectValidStructuredOutput() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(Self.validStdoutJSON, in: dispatch)

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: "session-abc"))
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        let result = try ResultFile.decode(contentsOf: resultFile, expecting: .worker)
        guard case .worker(let worker) = result, case .completed(let commit, let summary) = worker.outcome else {
            Issue.record("expected a completed worker result, got \(result)")
            return
        }
        #expect(commit == "0123456789abcdef0123456789abcdef01234567")
        #expect(summary == "ok")
    }

    @Test("collect: is_error true never materializes result.json")
    func collectIsErrorNoResultFile() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(
            #"{"session_id":"session-abc","is_error":true,"structured_output":\#(Self.structuredOutputJSON)}"#,
            in: dispatch
        )

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
    }

    @Test("collect: missing structured_output never materializes result.json")
    func collectMissingStructuredOutputNoResultFile() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(#"{"session_id":"session-abc","is_error":false}"#, in: dispatch)

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: "session-abc"))
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
    }

    @Test("collect: empty stdout falls back to the session id chosen at launch, never throws")
    func collectEmptyStdoutFallsBackToLaunchedSessionID() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        let launch = try adapter.launch(for: dispatch)
        let launchedSessionID = try #require(Self.value(after: "--session-id", in: launch.arguments))

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: launchedSessionID))
    }

    @Test("collect: garbage stdout never throws, falls back to the resumed session")
    func collectGarbageStdoutFallsBackToResumedSession() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let resume = CLISession(rawValue: "prior-session")
        let dispatch = fixture.dispatch(cli: "claude", resume: resume)
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout("not json at all {{{", in: dispatch)

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == resume)
    }

    @Test("collect: null members in structured_output are stripped, and the result still decodes")
    func collectStripsNullMembers() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        let structuredOutputWithNulls = """
            {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
            "commit":"0123456789abcdef0123456789abcdef01234567","summary":"ok",\
            "question":null,"reason":null}
            """
        try Self.writeStdout(
            #"{"session_id":"session-abc","is_error":false,"structured_output":\#(structuredOutputWithNulls)}"#,
            in: dispatch
        )

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        let data = try Data(contentsOf: resultFile)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["question"] == nil)
        #expect(object["reason"] == nil)

        let result = try ResultFile.decode(contentsOf: resultFile, expecting: .worker)
        guard case .worker(let worker) = result else {
            Issue.record("expected .worker(_), got \(result)")
            return
        }
        #expect(worker.outcome == .completed(commit: "0123456789abcdef0123456789abcdef01234567", summary: "ok"))
    }

    // MARK: - Helpers

    private static let structuredOutputJSON =
        """
        {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
        "commit":"0123456789abcdef0123456789abcdef01234567","summary":"ok"}
        """

    private static let validStdoutJSON =
        #"{"session_id":"session-abc","is_error":false,"structured_output":\#(structuredOutputJSON)}"#

    private static func writeStdout(_ text: String, in dispatch: CLIDispatch) throws {
        try Data(text.utf8).write(to: dispatch.runDirectory.appendingPathComponent("stdout.json"))
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.index(after: index) < args.count else { return nil }
        return args[args.index(after: index)]
    }

    static func indices(of flag: String, in args: [String]) -> [Int] {
        args.indices.filter { args[$0] == flag }
    }
}
