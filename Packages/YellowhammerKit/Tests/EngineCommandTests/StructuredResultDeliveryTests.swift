import Domain
@testable import EngineCommand
import Foundation
import Repositories
import Testing

/// Runs production instructions through EngineCommand dispatch and each adapter's launch/collection path.
/// Stub executables stand in for Codex and Claude; no live CLI is run.
@Suite("Structured result delivery through CLI adapters")
struct StructuredResultDeliveryTests {
    @Test(
        "Each production pass delivers structured output through fresh and resumed Codex and Claude runs",
        arguments: DeliveryCase.all
    )
    func everyPassUsesAdapterResultDelivery(_ testCase: DeliveryCase) async throws {
        let result = try await run(testCase)
        try assertCollectedResult(result)
        try assertPrompt(result)
        try assertAdapterArguments(result)
    }

    private func run(_ testCase: DeliveryCase) async throws -> DeliveryResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-structured-delivery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let capture = root.appendingPathComponent("argv.txt")
        let promptFile = root.appendingPathComponent("prompt.txt")
        let script = try Self.stubScript(in: root, cli: testCase.cli)
        let route = Self.route(for: testCase.cli)
        let request = Self.request(for: testCase, route: route, worktreePath: worktree.path)
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        let dispatch = CLIAdapterDispatch(
            runsDirectory: runs, timeout: .seconds(10), declaredExecutables: [testCase.cli: script.path], path: nil,
            environment: [
                "PATH": "/usr/bin:/bin", "CAPTURE": capture.path, "PROMPT": promptFile.path,
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
            schema: try? String(contentsOf: schemaURL, encoding: .utf8),
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
        #expect(!result.response.contains("null"))
    }

    private func assertPrompt(_ result: DeliveryResult) throws {
        let prompt = result.prompt
        let resultPath = result.runDirectory.appendingPathComponent("result.json").path
        #expect(prompt.contains("Return one JSON object as your final structured response"))
        #expect(prompt.contains("CLI/adapter persists it to `\(resultPath)`"))
        #expect(prompt.contains("do not create or edit that file with tools"))
        #expect(!prompt.contains("Write the result file"))
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
        if cli == "codex" {
            try assertCodexArguments(args, pass: pass, result: result, schemaPath: schemaPath)
        } else {
            assertClaudeArguments(args, pass: pass)
        }
    }

    private func assertCodexArguments(
        _ args: String, pass: RunPass, result: DeliveryResult, schemaPath: String
    ) throws {
        let resultPath = result.runDirectory.appendingPathComponent("result.json").path
        #expect(args.contains("-o\n\(resultPath)\n"))
        #expect(args.contains("--output-schema\n\(schemaPath)\n"))
        #expect(result.schema?.contains(pass.schemaIdentifier) == true)
        let sandbox = pass == .worker ? "workspace-write" : "read-only"
        #expect(args.contains("--sandbox\n\(sandbox)\n") || args.contains("sandbox_mode=\"\(sandbox)\""))
    }

    private func assertClaudeArguments(_ args: String, pass: RunPass) {
        let permissionMode = pass == .worker ? "acceptEdits" : "dontAsk"
        #expect(args.contains("--permission-mode\n\(permissionMode)\n"))
        #expect(args.contains(pass.schemaIdentifier))
        if pass == .worker {
            #expect(args.contains("Edit Write"))
        } else {
            #expect(args.contains("--disallowedTools\nEdit Write NotebookEdit\n"))
        }
    }

    private static func route(for cli: String) -> Route {
        Route(cli: cli, model: cli == "codex" ? "gpt-5.4" : "sonnet", effort: "medium")!
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
                adoptionCandidates: [], selectedFeature: nil, resultFilePath: ""
            ))
        case .verifier:
            return .verification(VerificationInstruction(
                route: route, featureTitle: "Feature", clauses: [],
                specificationSource: .specSource(SpecSource(path: "/repos/spec")),
                repositories: [VerificationRepository(
                    name: repo.name, directory: repo.path, featureBranch: "feature"
                )],
                resultFilePath: ""
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
                commitMessage: pass == .worker ? CommitMessageRequest(message: "fix: complete BACK-1") : nil,
                resultFilePath: ""
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

    private static func stubScript(in root: URL, cli: String) throws -> URL {
        let script = root.appendingPathComponent("stub-\(cli).sh")
        let capture = """
            printf '%s\\n' "$@" > "$CAPTURE"
            if [ "$CLI" = "claude" ]; then
                previous=""
                for arg in "$@"; do
                    if [ "$previous" = "-p" ]; then printf '%s' "$arg" > "$PROMPT"; break; fi
                    previous="$arg"
                done
            else
                last=""
                for arg in "$@"; do last="$arg"; done
                printf '%s' "$last" > "$PROMPT"
            fi
            """
        let output: String
        if cli == "codex" {
            output = """
                out=""
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = "-o" ]; then out="$2"; fi
                    shift
                done
                printf '%s' "$RESPONSE" > "$out"
                printf '{"type":"thread.started","thread_id":"stub-session"}\\n'
                """
        } else {
            output = """
                printf '{"session_id":"stub-session","is_error":false,"structured_output":%s}' "$RESPONSE"
                """
        }
        try "#!/bin/sh\n\(capture)\n\(output)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

struct DeliveryCase: Sendable, CustomStringConvertible {
    let cli: String
    let pass: RunPass
    let resume: Bool

    static let all = ["codex", "claude"].flatMap { cli in
        RunPass.allCases.flatMap { pass in
            [false, true].map { DeliveryCase(cli: cli, pass: pass, resume: $0) }
        }
    }

    var description: String { "\(cli) \(pass.rawValue) resumed=\(resume)" }
}

private struct DeliveryResult {
    let testCase: DeliveryCase
    let report: AgentDispatchReport
    let runDirectory: URL
    let resultExists: Bool
    let schema: String?
    let args: String
    let prompt: String
    let response: String
}
