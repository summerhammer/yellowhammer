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

    @Test("collect: a non-SUCCESS status never materializes result.json")
    func collectNonSuccessStatus() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "agy")
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(
            #"{"conversation_id":"conv-1","status":"ERROR","structured_output":{"summary":"x"}}"#, in: dispatch
        )

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: "conv-1"))
        #expect(!Self.resultExists(in: dispatch))
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
