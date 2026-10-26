import Domain
@testable import EngineCommand
import Foundation
import Repositories
import Testing

/// Runs production instructions through EngineCommand dispatch and each adapter's launch/collection path.
/// Stub executables stand in for Codex, Claude and Antigravity; no live CLI is run.
@Suite("Structured result delivery through CLI adapters")
struct StructuredResultDeliveryTests {
    @Test(
        "Each production pass delivers structured output through fresh and resumed Codex, Claude and agy runs",
        arguments: DeliveryCase.all
    )
    func everyPassUsesAdapterResultDelivery(_ testCase: DeliveryCase) async throws {
        let result = try await run(testCase)
        try assertCollectedResult(result)
        try assertPrompt(result)
        try assertAdapterArguments(result)
    }

    struct DeliveryCase: Sendable, CustomStringConvertible {
        let cli: String
        let pass: RunPass
        let resume: Bool

        static let all = RegisteredCLIAdapters.names.flatMap { cli in
            RunPass.allCases.flatMap { pass in
                [false, true].map { DeliveryCase(cli: cli, pass: pass, resume: $0) }
            }
        }

        var description: String { "\(cli) \(pass.rawValue) resumed=\(resume)" }
    }

    private func run(_ testCase: DeliveryCase) async throws -> DeliveryResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-structured-delivery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let capture = root.appendingPathComponent("argv.txt")
        let promptFile = root.appendingPathComponent("prompt.txt")
        // The runner removes the adapter's `schema.json` once the pass ends, so the stub copies what it read.
        let schemaSeen = root.appendingPathComponent("schema-seen.json")
        let script = try Self.stubScript(in: root, cli: testCase.cli)
        let route = Self.route(for: testCase.cli)
        let request = Self.request(for: testCase, route: route, worktreePath: worktree.path)
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        let dispatch = CLIAdapterDispatch(
            runsDirectory: runs, timeout: .seconds(10), declaredExecutables: [testCase.cli: script.path], path: nil,
            environment: [
                "PATH": "/usr/bin:/bin", "CAPTURE": capture.path, "PROMPT": promptFile.path,
                "SCHEMA_COPY": schemaSeen.path,
                "RESPONSE": Self.response(for: testCase.pass), "CLI": testCase.cli
            ],
            fileExists: { _ in true }
        )
        let report = try await dispatch.dispatch(request)
        let runDirectory = CLIAdapterDispatch.runDirectory(
            runsDirectory: runs, runID: request.runID, issueID: request.issueID,
            attemptID: request.attemptID, pass: request.pass
        )
        let resultURL = runDirectory.appendingPathComponent("result.json")
        let schemaURL = runDirectory.appendingPathComponent("schema.json")
        return DeliveryResult(
            testCase: testCase, report: report, runDirectory: runDirectory,
            resultExists: FileManager.default.fileExists(atPath: resultURL.path),
            schema: try? String(contentsOf: schemaSeen, encoding: .utf8),
            schemaRemoved: !FileManager.default.fileExists(atPath: schemaURL.path),
            args: try String(contentsOf: capture, encoding: .utf8),
            prompt: try String(contentsOf: promptFile, encoding: .utf8),
            response: try String(contentsOf: resultURL, encoding: .utf8)
        )
    }

    private func assertCollectedResult(_ result: DeliveryResult) throws {
        guard case .completed = result.report.outcome else {
            Issue.record("\(result.testCase) was not collected: \(result.report.outcome)")
            return
        }
        #expect(result.resultExists)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.response.utf8)) as? [String: Any])
        #expect(object["schema"] as? String == result.testCase.pass.schemaIdentifier)
        // Nullable-field normalization: the adapter drops the `null` members the forced schema requires.
        #expect(!object.values.contains { $0 is NSNull })
    }

    private func assertPrompt(_ result: DeliveryResult) throws {
        let prompt = result.prompt
        #expect(prompt.contains("Return one JSON object as your final structured response"))
        #expect(prompt.contains("The CLI Adapter persists it; do not create or edit a result file with tools."))
        // The pass is never told where its run directory is (issue #546).
        #expect(!prompt.contains(result.runDirectory.path))
        #expect(!prompt.contains("result.json"))
        #expect(prompt.contains(PassBoundaries.statement))
        #expect(prompt.contains("Ending without a final structured response is treated as a crash"))
        #expect(!prompt.contains("Write the result file"))
        #expect(!prompt.contains("result file is treated as a crash"))
        if result.testCase.pass == .worker {
            #expect(prompt.contains("You commit your work in the Worktree on the Feature branch"))
            #expect(prompt.contains("40-hex SHA of the commit you made"))
        }
    }

    private func assertAdapterArguments(_ result: DeliveryResult) throws {
        let cli = result.testCase.cli
        let pass = result.testCase.pass
        let args = result.args
        let schemaPath = result.runDirectory.appendingPathComponent("schema.json").path
        #expect(args.contains("--json-schema") || args.contains("--output-schema"))
        if result.testCase.resume {
            #expect(args.contains("prior-session"))
        }
        switch cli {
        case "codex":
            try assertCodexArguments(args, pass: pass, result: result, schemaPath: schemaPath)
        case "claude":
            assertClaudeArguments(args, pass: pass, runDirectory: result.runDirectory)
        case "agy":
            assertAntigravityArguments(args, pass: pass, resume: result.testCase.resume)
        default:
            Issue.record("no argument assertions for `\(cli)`")
        }
    }

    private func assertCodexArguments(
        _ args: String, pass: RunPass, result: DeliveryResult, schemaPath: String
    ) throws {
        let resultPath = result.runDirectory.appendingPathComponent("result.json").path
        #expect(args.contains("-o\n\(resultPath)\n"))
        #expect(args.contains("--output-schema\n\(schemaPath)\n"))
        #expect(result.schema?.contains(pass.schemaIdentifier) == true)
        #expect(result.schemaRemoved)
        let sandbox = pass == .worker ? "danger-full-access" : "read-only"
        #expect(args.contains("--sandbox\n\(sandbox)\n") || args.contains("sandbox_mode=\"\(sandbox)\""))
    }

    private func assertClaudeArguments(_ args: String, pass: RunPass, runDirectory: URL) {
        let settingsPath = runDirectory.appendingPathComponent("claude-settings.json").path
        #expect(args.contains("--settings\n\(settingsPath)\n"))
        let permissionMode = pass == .worker ? "acceptEdits" : "dontAsk"
        #expect(args.contains("--permission-mode\n\(permissionMode)\n"))
        #expect(args.contains("--output-format\nstream-json\n"))
        #expect(args.contains("--verbose\n"))
        #expect(args.contains(pass.schemaIdentifier))
        if pass == .worker {
            #expect(args.contains("Edit Write"))
            #expect(args.contains("--disallowedTools\nScheduleWakeup CronCreate Monitor Workflow RemoteTrigger\n"))
        } else {
            #expect(args.contains(
                "--disallowedTools\nEdit Write NotebookEdit ScheduleWakeup CronCreate Monitor Workflow RemoteTrigger\n"
            ))
        }
    }

    /// agy has no sandbox and no tool deny list: the rendered instruction is the only thing keeping a
    /// read-only pass from writing `result.json` itself, so the prompt assertions carry the most weight here.
    private func assertAntigravityArguments(_ args: String, pass: RunPass, resume: Bool) {
        #expect(args.contains("--json-schema\n"))
        #expect(args.contains(pass.schemaIdentifier))
        #expect(args.contains("--dangerously-skip-permissions\n"))
        #expect(!args.contains("--sandbox"))
        if resume {
            #expect(args.contains("--conversation\nprior-session\n"))
        } else {
            #expect(!args.contains("--conversation\n"))
        }
    }

    private static func route(for cli: String) -> Route {
        let model = switch cli {
        case "codex": "gpt-5.4"
        case "agy": "gemini-3-pro"
        default: "sonnet"
        }
        return Route(cli: cli, model: model, effort: "medium")!
    }

    private static func request(
        for testCase: DeliveryCase, route: Route, worktreePath: String
    ) -> AgentDispatchRequest {
        AgentDispatchRequest(
            runID: RunID(), issueID: testCase.pass.isAuthoring ? "authoring" : "BACK-1", attemptID: 1,
            route: route, pass: testCase.pass, instruction: instruction(for: testCase.pass, route: route),
            worktreePath: worktreePath, resumeSession: testCase.resume ? "prior-session" : nil,
            additionalReadableDirectories: [worktreePath],
            additionalWritableDirectories: [worktreePath + "/.git"]
        )
    }

    private static func instruction(for pass: RunPass, route: Route) -> AgentInstruction {
        let repo = Repo(name: "backend", path: "/repos/backend", role: .backend)
        switch pass {
        case .selection, .breakdown:
            return .authoring(AuthoringInstruction(
                pass: pass, route: route, specificationSource: .specSource(SpecSource(path: "/repos/spec")),
                specificationMainline: nil, repos: [repo], mainlines: ResolvedMainlines(), namedFeature: nil,
                adoptionCandidates: [], selectedFeature: nil
            ))
        case .verifier:
            return .verification(VerificationInstruction(
                route: route, featureTitle: "Feature", clauses: [],
                specificationSource: .specSource(SpecSource(path: "/repos/spec")),
                repositories: [VerificationRepository(
                    name: repo.name, directory: repo.path, featureBranch: "feature"
                )]
            ))
        case .architect, .worker, .reviewer:
            return .card(Instruction(
                pass: pass, card: InstructionCard(key: "BACK-1", title: "Delivery"),
                brief: ArchitecturalBrief(prose: "Implement the requested behavior.", transcriptions: []),
                definitionOfDone: [],
                repository: InstructionRepository(
                    repo: repo, worktreePath: "/worktree", featureBranch: "feature", check: .none
                ),
                route: route, payloads: .none,
                commitMessage: pass == .worker ? CommitMessageRequest(message: "fix: complete BACK-1") : nil
            ))
        }
    }

    private static func response(for pass: RunPass) -> String {
        switch pass {
        case .architect:
            #"{"schema":"yellowhammer.result.architect","version":1,"outcome":"failed","reason":"stub", "#
                + #""authoring_invariant_violation":null}"#
        case .worker:
            #"{"schema":"yellowhammer.result.worker","version":1,"outcome":"failed","reason":"stub", "#
                + #""commit":null,"summary":null,"question":null,"authoring_invariant_violation":null}"#
        case .reviewer:
            #"{"schema":"yellowhammer.result.reviewer","version":1,"verdict":"approved", "#
                + #""judged_commit":"0123456789abcdef0123456789abcdef01234567","summary":"stub", "#
                + #""requested_changes":null}"#
        case .selection:
            #"{"schema":"yellowhammer.result.selection","version":1,"outcome":"no_selectable_feature", "#
                + #""name":null,"reasoning":null,"sequence":null,"repositories":null,"adopted_card_issue_ids":null, "#
                + #""feature":null,"halt_cause":null,"halt_seam":null,"halt_repository":null,"reason":null}"#
        case .breakdown:
            #"{"schema":"yellowhammer.result.breakdown","version":1,"outcome":"failed","reason":"stub", "#
                + #""definition_of_done":null,"cards":null}"#
        case .verifier:
            #"{"schema":"yellowhammer.result.verifier","version":1,"outcome":"failed","reason":"stub", "#
                + #""clauses":null}"#
        }
    }

    /// Codex takes the instruction as the last positional argument; Claude and agy take it after `-p`.
    private static func stubScript(in root: URL, cli: String) throws -> URL {
        let script = root.appendingPathComponent("stub-\(cli).sh")
        let capture = """
            printf '%s\\n' "$@" > "$CAPTURE"
            if [ "$CLI" = "codex" ]; then
                last=""
                for arg in "$@"; do last="$arg"; done
                printf '%s' "$last" > "$PROMPT"
            else
                previous=""
                for arg in "$@"; do
                    if [ "$previous" = "-p" ]; then printf '%s' "$arg" > "$PROMPT"; break; fi
                    previous="$arg"
                done
            fi
            """
        let output = switch cli {
        case "codex":
            """
            out=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "-o" ]; then out="$2"; fi
                if [ "$1" = "--output-schema" ]; then cp "$2" "$SCHEMA_COPY"; fi
                shift
            done
            printf '%s' "$RESPONSE" > "$out"
            printf '{"type":"thread.started","thread_id":"stub-session"}\\n'
            """
        case "agy":
            """
            printf '{"conversation_id":"stub-session","status":"SUCCESS","structured_output":%s}' "$RESPONSE"
            """
        default:
            """
            printf '{"type":"system","subtype":"init","session_id":"stub-session"}\\n'
            printf '{"type":"result","subtype":"success","session_id":"stub-session",\
            "is_error":false,"structured_output":%s}\\n' "$RESPONSE"
            """
        }
        try "#!/bin/sh\n\(capture)\n\(output)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private struct DeliveryResult {
    let testCase: StructuredResultDeliveryTests.DeliveryCase
    let report: AgentDispatchReport
    let runDirectory: URL
    let resultExists: Bool
    let schema: String?
    let schemaRemoved: Bool
    let args: String
    let prompt: String
    let response: String
}
