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
        #expect(Self.value(after: "--output-format", in: args) == "stream-json")
        #expect(args.contains("--verbose"))
        #expect(Self.value(after: "--json-schema", in: args) == CLIOutputSchema.strict(for: .worker))
        #expect(Self.value(after: "--model", in: args) == "haiku")
        #expect(Self.value(after: "--effort", in: args) == "high")
        #expect(!args.contains("--resume"))
        let sessionID = try #require(Self.value(after: "--session-id", in: args))
        #expect(UUID(uuidString: sessionID) != nil)
        #expect(sessionID == sessionID.lowercased())
        #expect(Self.value(after: "--permission-mode", in: args) == "acceptEdits")
        #expect(Self.value(after: "--allowedTools", in: args) == "Bash Edit Write Read Glob Grep")
        #expect(Self.value(after: "--disallowedTools", in: args) == Self.workerDisallowed)
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
        #expect(Self.value(after: "--disallowedTools", in: args) == Self.readOnlyDisallowed)
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

    @Test("Additional readable directories become repeated --add-dir flags")
    func addDirFlagsForReadableDirectories() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "claude", pass: .selection, additionalReadableDirectories: ["/repos/backend", "/repos/mobile"]
        )

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(Self.indices(of: "--add-dir", in: args).count == 2)
        #expect(Self.value(after: "--add-dir", in: args) == "/repos/backend")
        #expect(Self.value(after: "--permission-mode", in: args) == "dontAsk")
        #expect(Self.value(after: "--disallowedTools", in: args) == Self.readOnlyDisallowed)
    }

    @Test("Both additional readable and writable directories become --add-dir flags in order")
    func addDirFlagsForBothReadableAndWritable() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "claude",
            additionalReadableDirectories: ["/read/1", "/read/2"],
            additionalWritableDirectories: ["/write/1"]
        )

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        let addDirIndices = Self.indices(of: "--add-dir", in: args)
        #expect(addDirIndices.count == 3)
        #expect(addDirIndices.map { args[$0 + 1] } == ["/read/1", "/read/2", "/write/1"])
    }

    @Test("Every pass streams results, runs verbose, and denies the follow-up tools (issue #643)",
          arguments: RunPass.allCases)
    func everyPassDeniesFollowUpTools(_ pass: RunPass) throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }

        let launch = try adapter.launch(for: fixture.dispatch(cli: "claude", pass: pass))
        let args = launch.arguments
        let disallowed = try #require(Self.value(after: "--disallowedTools", in: args))
        let denied = disallowed.split(separator: " ").map(String.init)

        for tool in ["ScheduleWakeup", "CronCreate", "Monitor", "Workflow", "RemoteTrigger"] {
            #expect(denied.contains(tool))
        }
        #expect(Self.value(after: "--output-format", in: args) == "stream-json")
        #expect(args.contains("--verbose"))
    }

    @Test("Every pass disables background tasks and keeps the dispatch's own environment", arguments: RunPass.allCases)
    func everyPassDisablesBackgroundTasks(_ pass: RunPass) throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude", pass: pass, environment: ["KEEP_ME": "yes"])

        let launch = try adapter.launch(for: dispatch)

        #expect(launch.environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1")
        #expect(launch.environment["KEEP_ME"] == "yes")
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
        try Self.writeStdout(Self.streamJSON(Self.resultEvent(Self.structuredOutputJSON, isError: true)), in: dispatch)

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
        try Self.writeStdout(Self.streamJSON(Self.resultEvent(nil)), in: dispatch)

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
        try Self.writeStdout(Self.streamJSON(Self.resultEvent(structuredOutputWithNulls)), in: dispatch)

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

    @Test("collect: a text-only result after a structured one keeps the structured result (issue #643)")
    func collectTextOnlyTurnAfterStructuredKeepsStructured() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(Self.streamJSON(
            Self.resultEvent(Self.workerResult(commit: Self.commitA), index: 0),
            Self.resultEvent(nil, index: 1)
        ), in: dispatch)

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(try Self.decodedCommit(dispatch) == Self.commitA)
    }

    @Test("collect: of two structured results, the last one wins")
    func collectLastStructuredResultWins() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(Self.streamJSON(
            Self.resultEvent(Self.workerResult(commit: Self.commitA), index: 0),
            Self.resultEvent(Self.workerResult(commit: Self.commitB), index: 1)
        ), in: dispatch)

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(try Self.decodedCommit(dispatch) == Self.commitB)
    }

    @Test("collect: an is_error result after a good structured one never replaces it")
    func collectErrorResultAfterStructuredKeepsStructured() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(Self.streamJSON(
            Self.resultEvent(Self.workerResult(commit: Self.commitA), index: 0),
            Self.resultEvent(Self.workerResult(commit: Self.commitB), index: 1, isError: true)
        ), in: dispatch)

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(try Self.decodedCommit(dispatch) == Self.commitA)
    }

    @Test("collect: a torn UTF-8 sequence on the last line never hides the structured result before it",
          arguments: Self.tornTails)
    func collectTornFinalLineKeepsEarlierResult(tail: [UInt8]) throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: dispatch)
        // A killed process can stop mid-character: the bytes after the complete result line are not valid UTF-8.
        var data = Data(Self.streamJSON(Self.resultEvent(Self.workerResult(commit: Self.commitA))).utf8)
        data.append(contentsOf: tail)
        try data.write(to: dispatch.runDirectory.appendingPathComponent("stdout.json"))

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(try Self.decodedCommit(dispatch) == Self.commitA)
    }

    @Test("A Round never reads the previous Round's output: it is set aside, and a text-only Round 2 yields no result")
    func roundNeverReadsPreviousRoundOutput() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let round1 = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: round1)
        let round1Stdout = Self.streamJSON(Self.resultEvent(Self.workerResult(commit: Self.commitA)))
        try Self.writeStdout(round1Stdout, in: round1)
        _ = adapter.collect(end: .exited(status: 0), dispatch: round1)
        let resultFile = fixture.runDirectory.appendingPathComponent("result.json")
        #expect(FileManager.default.fileExists(atPath: resultFile.path))

        let round2 = fixture.dispatch(cli: "claude", resume: CLISession(rawValue: "session-abc"))
        _ = try adapter.launch(for: round2)
        // The Round 2 process appends to whatever capture the run directory holds (`O_APPEND`).
        try Self.appendStdout(Self.streamJSON(Self.resultEvent(nil)), in: round2)

        _ = adapter.collect(end: .exited(status: 0), dispatch: round2)

        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
        let setAside = try Data(contentsOf: fixture.runDirectory.appendingPathComponent("stdout.1.json"))
        #expect(setAside == Data(round1Stdout.utf8))
    }

    @Test("A second rotation moves the next capture to stdout.2.json and keeps stdout.1.json intact")
    func secondRotationUsesNextFreeName() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let round1 = fixture.dispatch(cli: "claude")
        _ = try adapter.launch(for: round1)
        let firstCapture = Self.streamJSON(Self.resultEvent(nil))
        try Self.writeStdout(firstCapture, in: round1)

        let resume = CLISession(rawValue: "session-abc")
        let round2 = fixture.dispatch(cli: "claude", resume: resume)
        _ = try adapter.launch(for: round2)
        let secondCapture = Self.streamJSON(Self.resultEvent(nil, index: 0))
        try Self.writeStdout(secondCapture, in: round2)

        let round3 = fixture.dispatch(cli: "claude", resume: resume)
        _ = try adapter.launch(for: round3)

        let directory = fixture.runDirectory
        let kept1 = try Data(contentsOf: directory.appendingPathComponent("stdout.1.json"))
        let kept2 = try Data(contentsOf: directory.appendingPathComponent("stdout.2.json"))
        #expect(kept1 == Data(firstCapture.utf8))
        #expect(kept2 == Data(secondCapture.utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("stdout.json").path))
    }

    // MARK: - Helpers

    private static let commitA = "0123456789abcdef0123456789abcdef01234567"
    private static let commitB = "fedcba9876543210fedcba9876543210fedcba98"

    /// Torn final lines: an unfinished object, and one whose `"result"` key is cut inside a multi-byte sequence.
    private static let tornTails: [[UInt8]] = [
        [0x7B, 0x22, 0xE2, 0x82],
        [0x7B, 0x22, 0x72, 0x65, 0x73, 0x75, 0x6C, 0x74, 0x22, 0x3A, 0x22, 0xE2, 0x82]
    ]

    /// A worker's `--disallowedTools`: the follow-up tools every pass denies, and nothing else.
    private static let workerDisallowed = "ScheduleWakeup CronCreate Monitor Workflow RemoteTrigger"

    /// A read-only pass's `--disallowedTools`: the file tools, then the follow-up tools every pass denies.
    private static let readOnlyDisallowed =
        "Edit Write NotebookEdit ScheduleWakeup CronCreate Monitor Workflow RemoteTrigger"

    private static let structuredOutputJSON = workerResult(commit: commitA)

    private static let validStdoutJSON = streamJSON(resultEvent(structuredOutputJSON))

    private static let initLine = #"{"type":"system","subtype":"init","session_id":"session-abc"}"#

    /// A worker `StructuredOutput` object, as the forced schema prints it.
    private static func workerResult(commit: String) -> String {
        """
        {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
        "commit":"\(commit)","summary":"ok"}
        """
    }

    /// One `type:result` event, the per-turn record `stream-json` prints. `structured` is the
    /// `structured_output` object, or nil for a text-only turn.
    private static func resultEvent(
        _ structured: String?, index: Int = 0, isError: Bool = false, sessionID: String = "session-abc"
    ) -> String {
        var fields = [
            #""type":"result""#, #""subtype":"success""#, #""session_id":"\#(sessionID)""#,
            #""is_error":\#(isError)"#, #""result_index":\#(index)"#, #""result":"done""#
        ]
        if let structured {
            fields.append(#""structured_output":\#(structured)"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// The JSON Lines `--output-format stream-json --verbose` prints: a system init line, then the
    /// given events. Every line ends in a newline, as the CLI writes it.
    private static func streamJSON(_ events: String...) -> String {
        ([initLine] + events).map { $0 + "\n" }.joined()
    }

    private static func writeStdout(_ text: String, in dispatch: CLIDispatch) throws {
        try Data(text.utf8).write(to: dispatch.runDirectory.appendingPathComponent("stdout.json"))
    }

    /// Appends to the capture, as the `O_APPEND` spawn of a later Round does.
    private static func appendStdout(_ text: String, in dispatch: CLIDispatch) throws {
        let file = dispatch.runDirectory.appendingPathComponent("stdout.json")
        let existing = (try? Data(contentsOf: file)) ?? Data()
        try (existing + Data(text.utf8)).write(to: file)
    }

    /// The commit of the completed worker result `collect` wrote, failing the test if there is none.
    private static func decodedCommit(_ dispatch: CLIDispatch) throws -> String? {
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        let result = try ResultFile.decode(contentsOf: resultFile, expecting: .worker)
        guard case .worker(let worker) = result, case .completed(let commit, _) = worker.outcome else {
            Issue.record("expected a completed worker result, got \(result)")
            return nil
        }
        return commit
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), args.index(after: index) < args.count else { return nil }
        return args[args.index(after: index)]
    }

    static func indices(of flag: String, in args: [String]) -> [Int] {
        args.indices.filter { args[$0] == flag }
    }
}
