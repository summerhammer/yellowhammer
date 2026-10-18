@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("CodexAdapter")
struct CodexAdapterTests {
    private let adapter = CodexAdapter()

    // MARK: - argv shape

    @Test("First dispatch, worker: workspace-write sandbox, schema and -o point at runDirectory")
    func firstDispatchWorkerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex", model: "gpt-5.5", effort: "low", pass: .worker)

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(args[0] == "exec")
        #expect(args.contains("--json"))
        #expect(ClaudeCodeAdapterTests.value(after: "--sandbox", in: args) == "workspace-write")
        #expect(ClaudeCodeAdapterTests.value(after: "-m", in: args) == "gpt-5.5")
        let effortConfig = try #require(Self.configValues(in: args)["model_reasoning_effort"])
        #expect(effortConfig == "\"low\"")
        let schemaPath = try #require(ClaudeCodeAdapterTests.value(after: "--output-schema", in: args))
        #expect(schemaPath == dispatch.runDirectory.appendingPathComponent("schema.json").path)
        #expect(FileManager.default.fileExists(atPath: schemaPath))
        let schemaContents = try String(contentsOfFile: schemaPath, encoding: .utf8)
        #expect(schemaContents == CLIOutputSchema.strict(for: .worker))
        let outputPath = try #require(ClaudeCodeAdapterTests.value(after: "-o", in: args))
        #expect(outputPath == dispatch.runDirectory.appendingPathComponent("result.json").path)
        #expect(!args.contains("resume"))
        // The instruction goes after `--`, in its own positional slot.
        let dashIndex = try #require(args.firstIndex(of: "--"))
        #expect(args[dashIndex + 1] == dispatch.instruction)
        #expect(args.count == dashIndex + 2)
    }

    @Test("Round, worker: exec resume, sandbox and writable roots re-stated with -c, no --sandbox/-C")
    func roundWorkerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let session = CLISession(rawValue: "thread-123")
        let dispatch = fixture.dispatch(
            cli: "codex", model: "gpt-5.5", effort: "low", pass: .worker, resume: session,
            additionalWritableDirectories: ["/some/gitdir"]
        )

        let launch = try adapter.launch(for: dispatch)
        let args = launch.arguments

        #expect(args[0] == "exec")
        #expect(args[1] == "resume")
        #expect(!args.contains("--sandbox"))
        #expect(!args.contains("-C"))
        #expect(!args.contains("--add-dir"))
        let config = Self.configValues(in: args)
        #expect(config["sandbox_mode"] == "\"workspace-write\"")
        #expect(config["sandbox_workspace_write.writable_roots"] == "[\"/some/gitdir\"]")
        #expect(config["model_reasoning_effort"] == "\"low\"")
        let dashIndex = try #require(args.firstIndex(of: "--"))
        #expect(args[dashIndex + 1] == "thread-123")
        #expect(args[dashIndex + 2] == dispatch.instruction)
        #expect(args.count == dashIndex + 3)
    }

    @Test("First dispatch, reviewer: read-only sandbox")
    func firstDispatchReviewerArgv() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex", pass: .reviewer)

        let launch = try adapter.launch(for: dispatch)

        #expect(ClaudeCodeAdapterTests.value(after: "--sandbox", in: launch.arguments) == "read-only")
        let schemaPath = try #require(ClaudeCodeAdapterTests.value(after: "--output-schema", in: launch.arguments))
        let schemaContents = try String(contentsOfFile: schemaPath, encoding: .utf8)
        #expect(schemaContents == CLIOutputSchema.strict(for: .reviewer))
    }

    @Test("Round, reviewer: read-only sandbox, no writable-roots override without extra dirs")
    func roundReviewerArgvNoWritableRoots() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex", pass: .reviewer, resume: CLISession(rawValue: "thread-9"))

        let launch = try adapter.launch(for: dispatch)
        let config = Self.configValues(in: launch.arguments)

        #expect(config["sandbox_mode"] == "\"read-only\"")
        #expect(config["sandbox_workspace_write.writable_roots"] == nil)
    }

    // MARK: - Protected directories (issue #557)

    private static let protectedDirectories = ["/Users/x/.config/yellowhammer", "/Users/x/Library/Keychains"]
    private static let expectedDenials =
        "{\"/Users/x/.config/yellowhammer\"=\"deny\",\"/Users/x/Library/Keychains\"=\"deny\"}"

    @Test(
        "First dispatch, read-only pass with protected directories: a deny profile replaces --sandbox",
        arguments: [RunPass.architect, .reviewer, .selection, .breakdown, .verifier]
    )
    func firstReadOnlyDispatchDeniesProtectedDirectories(pass: RunPass) throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex", pass: pass, protectedDirectories: Self.protectedDirectories)

        let args = try adapter.launch(for: dispatch).arguments
        let config = Self.configValues(in: args)

        // `--sandbox` overrides `default_permissions` (measured with codex-cli 0.163.0), so it must be gone.
        #expect(!args.contains("--sandbox"))
        #expect(config["sandbox_mode"] == nil)
        #expect(config["default_permissions"] == "\"yellowhammer\"")
        #expect(config["permissions.yellowhammer.extends"] == "\":read-only\"")
        #expect(config["permissions.yellowhammer.filesystem"] == Self.expectedDenials)
        let dashIndex = try #require(args.firstIndex(of: "--"))
        #expect(args[dashIndex + 1] == dispatch.instruction)
        #expect(args.count == dashIndex + 2)
    }

    @Test("Round, read-only pass with protected directories: the deny profile replaces -c sandbox_mode")
    func roundReadOnlyDispatchDeniesProtectedDirectories() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "codex", pass: .architect, resume: CLISession(rawValue: "thread-7"),
            protectedDirectories: Self.protectedDirectories
        )

        let args = try adapter.launch(for: dispatch).arguments
        let config = Self.configValues(in: args)

        #expect(args[0] == "exec")
        #expect(args[1] == "resume")
        #expect(!args.contains("--sandbox"))
        #expect(config["sandbox_mode"] == nil)
        #expect(config["default_permissions"] == "\"yellowhammer\"")
        #expect(config["permissions.yellowhammer.extends"] == "\":read-only\"")
        #expect(config["permissions.yellowhammer.filesystem"] == Self.expectedDenials)
        let dashIndex = try #require(args.firstIndex(of: "--"))
        #expect(args[dashIndex + 1] == "thread-7")
        #expect(args[dashIndex + 2] == dispatch.instruction)
    }

    @Test("The worker is never given the deny profile, fresh or resumed")
    func workerIgnoresProtectedDirectories() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let fresh = fixture.dispatch(cli: "codex", pass: .worker, protectedDirectories: Self.protectedDirectories)
        let resumed = fixture.dispatch(
            cli: "codex", pass: .worker, resume: CLISession(rawValue: "thread-8"),
            protectedDirectories: Self.protectedDirectories
        )

        let freshArgs = try adapter.launch(for: fresh).arguments
        #expect(ClaudeCodeAdapterTests.value(after: "--sandbox", in: freshArgs) == "workspace-write")
        #expect(Self.configValues(in: freshArgs)["default_permissions"] == nil)

        let resumedConfig = Self.configValues(in: try adapter.launch(for: resumed).arguments)
        #expect(resumedConfig["sandbox_mode"] == "\"workspace-write\"")
        #expect(resumedConfig["default_permissions"] == nil)
    }

    @Test("A protected directory with a quote is escaped as a TOML string key")
    func protectedDirectoryIsTOMLEscaped() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex", pass: .reviewer, protectedDirectories: ["/a \"b\"/c"])

        let config = Self.configValues(in: try adapter.launch(for: dispatch).arguments)

        #expect(config["permissions.yellowhammer.filesystem"] == "{\"/a \\\"b\\\"/c\"=\"deny\"}")
    }

    @Test("The adapter version moved to 3 with the deny profile")
    func adapterVersionIsThree() {
        #expect(adapter.adapterVersion == "3")
    }

    @Test("Additional writable directories become repeated --add-dir flags on a first dispatch")
    func addDirFlagsOnFirstDispatch() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex", additionalWritableDirectories: ["/a", "/b"])

        let launch = try adapter.launch(for: dispatch)

        #expect(ClaudeCodeAdapterTests.indices(of: "--add-dir", in: launch.arguments).count == 2)
    }

    @Test("Additional readable directories do not become --add-dir flags in Codex")
    func readableDirectoriesProduceNoAddDirFlagsInCodex() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(
            cli: "codex", pass: .selection, additionalReadableDirectories: ["/repos/backend", "/repos/mobile"]
        )

        let launch = try adapter.launch(for: dispatch)

        #expect(!launch.arguments.contains("--add-dir"))
        #expect(ClaudeCodeAdapterTests.value(after: "--sandbox", in: launch.arguments) == "read-only")
    }

    @Test("Forbidden flags never appear")
    func forbiddenFlagsNeverAppear() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let launch = try adapter.launch(for: fixture.dispatch(cli: "codex"))

        for forbidden in ["--ignore-user-config", "--skip-git-repo-check"] {
            #expect(!launch.arguments.contains(forbidden))
        }
        #expect(!launch.arguments.contains { $0.hasPrefix("--dangerously-") })
    }

    // MARK: - Refusals

    @Test("A Route for another CLI is refused")
    func wrongCLIRefused() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        #expect(throws: CLIAdapterError.routeForOtherCLI(expected: "codex", got: "claude")) {
            try adapter.launch(for: fixture.dispatch(cli: "claude"))
        }
    }

    @Test("An unsupported effort is refused")
    func unsupportedEffortRefused() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        #expect(throws: CLIAdapterError.unsupportedEffort(
            cli: "codex", effort: "ultra", supported: adapter.supportedEfforts
        )) {
            try adapter.launch(for: fixture.dispatch(cli: "codex", effort: "ultra"))
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

        _ = try adapter.launch(for: fixture.dispatch(cli: "codex"))

        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
    }

    // MARK: - collect

    @Test("collect: a thread.started JSONL line yields the session, result file untouched")
    func collectThreadStarted() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex")
        _ = try adapter.launch(for: dispatch)
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        try Data("codex wrote this".utf8).write(to: resultFile)
        try Self.writeStdout(
            """
            {"type":"thread.started","thread_id":"thread-xyz"}
            {"type":"turn.completed"}
            """,
            in: dispatch
        )

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == CLISession(rawValue: "thread-xyz"))
        let contents = try String(contentsOf: resultFile, encoding: .utf8)
        #expect(contents == "codex wrote this")
    }

    @Test("collect: missing thread.started falls back to the resumed session")
    func collectMissingThreadStartedFallsBack() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let resume = CLISession(rawValue: "prior-thread")
        let dispatch = fixture.dispatch(cli: "codex", resume: resume)
        _ = try adapter.launch(for: dispatch)
        try Self.writeStdout(#"{"type":"turn.completed"}"#, in: dispatch)

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == resume)
    }

    @Test("collect: no stdout at all never throws, returns nil when there is no resumed session")
    func collectNoStdoutReturnsNil() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex")
        _ = try adapter.launch(for: dispatch)

        let session = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

        #expect(session == nil)
    }

    @Test("collect: a result.json codex wrote with strict-mode null members is normalized and decodes")
    func collectNormalizesNullMembersInResultFile() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let dispatch = fixture.dispatch(cli: "codex")
        _ = try adapter.launch(for: dispatch)
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        let withNulls = """
            {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
            "commit":"0123456789abcdef0123456789abcdef01234567","summary":"ok",\
            "question":null,"reason":null}
            """
        try Data(withNulls.utf8).write(to: resultFile)

        _ = adapter.collect(end: .exited(status: 0), dispatch: dispatch)

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

    private static func writeStdout(_ text: String, in dispatch: CLIDispatch) throws {
        try Data(text.utf8).write(to: dispatch.runDirectory.appendingPathComponent("stdout.jsonl"))
    }

    /// Parses every `-c key=value` pair in `args` into a dictionary, keyed by `key`.
    private static func configValues(in args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            if args[index] == "-c", index + 1 < args.count {
                let pair = args[index + 1]
                if let equals = pair.firstIndex(of: "=") {
                    result[String(pair[pair.startIndex..<equals])] = String(pair[pair.index(after: equals)...])
                }
            }
            index += 1
        }
        return result
    }
}
