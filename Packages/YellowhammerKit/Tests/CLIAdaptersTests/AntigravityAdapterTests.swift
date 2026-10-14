@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("AntigravityAdapter")
struct AntigravityAdapterTests {
    private let adapter = AntigravityAdapter()

    // MARK: - argv shape

    @Test("First dispatch, worker: forces schema, skips permissions, no sandbox, mode or conversation")
    func firstDispatchWorkerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy", model: "gemini-3.8-flash-low", effort: "high", pass: .worker)

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(args[0] == "-p")
        #expect(args[1] == dispatch.instruction)
        #expect(Self.value(after: "--output-format", in: args) == "json")
        #expect(Self.value(after: "--json-schema", in: args) == CLIOutputSchema.gemini(for: .worker))
        #expect(Self.value(after: "--model", in: args) == "gemini-3.8-flash-low")
        #expect(Self.value(after: "--effort", in: args) == "high")
        #expect(!args.contains("--conversation"))
        #expect(args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--sandbox"))
        #expect(!args.contains("--mode"))
    }

    @Test("Round: passes --conversation with the prior session id")
    func roundArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy", resume: CLISession(rawValue: "prior-conversation"))

        let args = try adapter.launch(for: dispatch).arguments

        #expect(Self.value(after: "--conversation", in: args) == "prior-conversation")
        #expect(args.contains("--dangerously-skip-permissions"))
    }

    @Test("Reviewer pass gets the reviewer schema")
    func reviewerSchema() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy", pass: .reviewer)

        let args = try adapter.launch(for: dispatch).arguments

        #expect(Self.value(after: "--json-schema", in: args) == CLIOutputSchema.gemini(for: .reviewer))
        #expect(args.contains("--dangerously-skip-permissions"))
        #expect(!args.contains("--sandbox"))
    }

    @Test("Readable then writable directories become repeated --add-dir flags in order")
    func addDirFlags() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "agy",
            additionalReadableDirectories: ["/read/1", "/read/2"],
            additionalWritableDirectories: ["/write/1"]
        )

        let args = try adapter.launch(for: dispatch).arguments

        let addDirIndices = Self.indices(of: "--add-dir", in: args)
        #expect(addDirIndices.map { args[$0 + 1] } == ["/read/1", "/read/2", "/write/1"])
    }

    // MARK: - Refusals

    @Test("A Route for another CLI is refused")
    func wrongCLIRefused() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }

        #expect(throws: CLIAdapterError.routeForOtherCLI(expected: "agy", got: "claude")) {
            try adapter.launch(for: fixture.dispatch(cli: "claude"))
        }
    }

    @Test("An unsupported effort is refused")
    func unsupportedEffortRefused() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }

        #expect(throws: CLIAdapterError.unsupportedEffort(
            cli: "agy", effort: "minimal", supported: adapter.supportedEfforts
        )) {
            try adapter.launch(for: fixture.dispatch(cli: "agy", effort: "minimal"))
        }
    }

    @Test("A stale result.json in runDirectory is removed before launch")
    func staleResultFileRemoved() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.runDirectory, withIntermediateDirectories: true)
        let resultFile = fixture.runDirectory.appendingPathComponent("result.json")
        try Data("stale".utf8).write(to: resultFile)

        _ = try adapter.launch(for: fixture.dispatch(cli: "agy"))

        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
    }

    // MARK: - collect

    @Test("collect: success JSON writes result.json with null members stripped and returns conversation_id")
    func collectSuccess() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)
        let structured = """
            {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
            "commit":"0123456789abcdef0123456789abcdef01234567","summary":"ok",\
            "question":null,"reason":null}
            """
        try Self.writeStdout(
            #"{"conversation_id":"conv-1","status":"SUCCESS","structured_output":\#(structured)}"#, in: dispatch
        )

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: "conv-1"))
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: resultFile)) as? [String: Any]
        )
        #expect(object["question"] == nil)
        #expect(object["reason"] == nil)
        let result = try ResultFile.decode(contentsOf: resultFile, expecting: .worker)
        guard case .worker(let worker) = result else {
            Issue.record("expected .worker(_), got \(result)")
            return
        }
        #expect(worker.outcome == .completed(commit: "0123456789abcdef0123456789abcdef01234567", summary: "ok"))
    }

    @Test("collect: SUCCESS without structured_output writes no result.json")
    func collectMissingStructuredOutput() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(#"{"conversation_id":"conv-1","status":"SUCCESS"}"#, in: dispatch)

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: "conv-1"))
        #expect(!Self.resultExists(in: dispatch))
    }

    @Test("collect: null structured_output writes no result.json")
    func collectNullStructuredOutput() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(
            #"{"conversation_id":"conv-1","status":"SUCCESS","structured_output":null}"#, in: dispatch
        )

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(!Self.resultExists(in: dispatch))
    }

    @Test("collect: recovered API errors preserve the same result bytes and session as SUCCESS")
    func collectRecoveredAPIError() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy", pass: .architect)
        let launch = try adapter.launch(for: dispatch)
        try Self.writeStdout(try Self.architectStdout(status: "SUCCESS"), in: dispatch)
        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch) == CLISession(rawValue: "conv-1"))
        let successBytes = try Data(contentsOf: launch.resultFile)

        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(try Self.architectStdout(status: "ERROR"), in: dispatch)
        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch) == CLISession(rawValue: "conv-1"))
        let recoveredBytes = try Data(contentsOf: launch.resultFile)
        #expect(recoveredBytes == successBytes)
        let object = try #require(try JSONSerialization.jsonObject(with: recoveredBytes) as? [String: Any])
        #expect(object["reason"] == nil)
        #expect(object["authoring_invariant_violation"] == nil)
        let decoded = try ResultFile.decode(recoveredBytes, expecting: .architect)
        #expect(RunOutcome.classify(end: .exited(status: 0), resultFileAt: launch.resultFile, pass: .architect)
            == .completed(decoded))
    }

    @Test("collect: without an output object writes no result.json",
          arguments: ["SUCCESS", "ERROR"],
          ["", #", "structured_output": null"#, #", "structured_output": []"#,
           #", "structured_output": "unfinished""#, #", "structured_output": 1"#])
    func collectWithoutOutputObject(status: String, outputMember: String) throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(
            #"{"conversation_id":"conv-1","status":"\#(status)","error":"interrupted"\#(outputMember)}"#,
            in: dispatch
        )

        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch) == CLISession(rawValue: "conv-1"))
        #expect(!Self.resultExists(in: dispatch))
        if status == "ERROR" {
            let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
            let outcome = RunOutcome.classify(end: .exited(status: 0), resultFileAt: resultFile, pass: dispatch.pass)
            guard case .crashedUnknown(.resultFile) = outcome else {
                Issue.record("expected a missing result file to remain Crashed-Unknown, got \(outcome)")
                return
            }
        }
    }

    @Test("collect: empty stdout on a first dispatch returns nil, never throws")
    func collectEmptyStdout() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)

        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch) == nil)
    }

    @Test("collect: garbage stdout falls back to the resumed session")
    func collectGarbageStdout() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let resume = CLISession(rawValue: "prior-conversation")
        let dispatch = fixture.dispatch(cli: "agy", resume: resume)
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout("not json at all {{{", in: dispatch)

        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch) == resume)
    }

    @Test("collect: with multiple JSON lines the last parseable object wins")
    func collectLastParseableObjectWins() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(
            """
            {"conversation_id":"first","status":"SUCCESS"}
            {"conversation_id":"second","status":"SUCCESS"}
            not json
            """,
            in: dispatch
        )

        #expect(adapter.collect(end: .exited(status: 0), dispatch: dispatch) == CLISession(rawValue: "second"))
    }

    // MARK: - Helpers

    /// Matches agy's observed final stdout envelope, including sticky error metadata after recovery.
    private static func architectStdout(status: String) throws -> String {
        let object: [String: Any] = [
            "conversation_id": "conv-1",
            "status": status,
            "error": status == "ERROR"
                ? "API error (attempt 8): INTERNAL (code 500): Internal error encountered." : "",
            "response": "",
            "duration_seconds": 302.4,
            "num_turns": 144,
            "structured_output": [
                "schema": "yellowhammer.result.architect", "version": 1, "outcome": "planned",
                "plan": "Preserve structured output after recovered API retries.",
                "affected_paths": ["Sources/CLIAdapters/AntigravityAdapter.swift"],
                "reason": NSNull(), "authoring_invariant_violation": NSNull()
            ],
            "json_schema": try JSONSerialization.jsonObject(with: Data(CLIOutputSchema.gemini(for: .architect).utf8)),
            "usage": ["input_tokens": 2048, "output_tokens": 512]
        ]
        return try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    private static func resultExists(in dispatch: CLIDispatch) -> Bool {
        FileManager.default.fileExists(atPath: dispatch.runDirectory.appendingPathComponent("result.json").path)
    }

    private static func writeStdout(_ text: String, in dispatch: CLIDispatch) throws {
        try Data(text.utf8).write(to: dispatch.runDirectory.appendingPathComponent("stdout.json"))
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        ClaudeCodeAdapterTests.value(after: flag, in: args)
    }

    private static func indices(of flag: String, in args: [String]) -> [Int] {
        ClaudeCodeAdapterTests.indices(of: flag, in: args)
    }
}
