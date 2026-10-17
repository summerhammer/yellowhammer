import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("Claude and Codex usage-limit refusal translation")
struct CLIUsageLimitTests {
    private static let claudeHint = "You've hit your session limit · resets 2:20pm (Europe/Kiev)"
    private static let codexHint = "You’ve hit your usage limit. Please try again at 2:55 PM."

    @Test("Claude's recorded subscription refusal is distinct from exit failure")
    func claudeRefusal() async throws {
        let payload: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": true, "terminal_reason": "api_error",
            "api_error_status": 429, "api_error_origin": "first_party", "api_error": "usage_limit_reached",
            "result": Self.claudeHint
        ]
        let outcome = try await runClaude(payload)
        #expect(outcome == .usageLimited(resetHint: Self.claudeHint))
    }

    @Test("Claude's structured code works without a reset hint")
    func claudeWithoutHint() async throws {
        let outcome = try await runClaude([
            "type": "result", "is_error": true, "api_error": "usage_limit_reached"
        ])
        #expect(outcome == .usageLimited(resetHint: nil))
    }

    @Test("An unrelated Claude 429 or a quoted limit is still an ordinary failure", arguments: 0..<3)
    func claudeOtherErrors(scenario: Int) async throws {
        let payloads: [[String: Any]] = [
            ["type": "result", "is_error": true, "api_error_status": 429, "api_error": "overloaded"],
            ["type": "result", "is_error": false, "api_error": "usage_limit_reached"],
            ["type": "assistant", "is_error": true, "api_error": "usage_limit_reached"]
        ]
        let outcome = try await runClaude(payloads[scenario])
        #expect(outcome == .failed(exitStatus: 1))
    }

    @Test("Codex recognizes either reported refusal event", arguments: ["error", "turn.failed"])
    func codexRefusal(event: String) async throws {
        let payload: [String: Any] = event == "error"
            ? ["type": event, "message": Self.codexHint]
            : ["type": event, "error": ["message": Self.codexHint]]
        let outcome = try await runCodex(payload)
        #expect(outcome == .usageLimited(resetHint: Self.codexHint))
    }

    @Test("Codex recognizes the straight apostrophe variant")
    func codexStraightApostrophe() async throws {
        let message = "You've hit your usage limit."
        let outcome = try await runCodex(["type": "error", "message": message])
        #expect(outcome == .usageLimited(resetHint: message))
    }

    @Test("Codex ignores model text and unrelated errors", arguments: [
        ["type": "item.completed", "message": "You’ve hit your usage limit."],
        ["type": "error", "message": "Request failed with status 429"],
        ["type": "error", "message": "The fixture says: You've hit your usage limit."]
    ])
    func codexOtherErrors(payload: [String: String]) async throws {
        let outcome = try await runCodex(payload)
        #expect(outcome == .failed(exitStatus: 1))
    }

    private func runClaude(_ payload: [String: Any]) async throws -> RunOutcome {
        try await run(payload, adapter: ClaudeCodeAdapter())
    }

    private func runCodex(_ payload: [String: Any]) async throws -> RunOutcome {
        try await run(payload, adapter: CodexAdapter())
    }

    private func run(_ payload: [String: Any], adapter: some CLIAdapter) async throws -> RunOutcome {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let capturedOutput = fixture.tempDir.appendingPathComponent("payload.json")
        try data.write(to: capturedOutput)
        let script = fixture.tempDir.appendingPathComponent("cli.sh")
        // The payload is a separate file so apostrophes in vendor messages remain literal.
        try "#!/bin/sh\ncat \"$YH_REFUSAL_FIXTURE\"\nexit 1\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let dispatch = fixture.dispatch(
            cli: adapter.cli, executable: script.path, environment: ["YH_REFUSAL_FIXTURE": capturedOutput.path]
        )
        let report = try await CLIRunner().run(dispatch, adapter: adapter)
        #expect(report.end == .exited(status: 1))
        return report.outcome
    }
}
