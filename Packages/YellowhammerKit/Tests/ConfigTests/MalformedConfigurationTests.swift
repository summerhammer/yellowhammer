import Config
import Foundation
import Testing

struct MalformedFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let line: Int
    let key: String?
    /// nil expects a TOML syntax error, whatever its message.
    let reason: ConfigurationError.Reason?

    init(_ name: String, line: Int, key: String?, _ reason: ConfigurationError.Reason? = nil) {
        self.name = name
        self.line = line
        self.key = key
        self.reason = reason
    }

    var testDescription: String { name }
}

private let syntaxFixtures: [MalformedFixture] = [
    MalformedFixture("syntax-unterminated-string", line: 2, key: "linear.credential"),
    MalformedFixture("syntax-bad-value", line: 2, key: "linear.credential"),
    MalformedFixture("syntax-missing-equals", line: 2, key: "linear.credential"),
    MalformedFixture("syntax-invalid-escape", line: 4, key: "linear.credential"),
    MalformedFixture("syntax-stray-character", line: 2, key: nil),
    MalformedFixture("syntax-bad-array-element", line: 11, key: "routing[0].fallbacks[1]"),
    MalformedFixture("syntax-inline-table-trailing-comma", line: 8, key: "routing[0].route"),
    MalformedFixture("duplicate-key", line: 3, key: "linear.credential", .duplicateKey(firstLine: 2)),
    MalformedFixture("table-redefined", line: 7, key: "linear", .tableRedefined(firstLine: 1))
]

private let shapeFixtures: [MalformedFixture] = [
    MalformedFixture("missing-linear", line: 1, key: "linear", .missingTable),
    MalformedFixture("missing-linear-credential", line: 2, key: "linear.credential", .missingKey),
    MalformedFixture("missing-linear-client-id", line: 1, key: "linear.client_id", .missingKey),
    MalformedFixture("missing-github-credential", line: 4, key: "github.credential", .missingKey),
    MalformedFixture("empty-credential", line: 5, key: "github.credential", .emptyString),
    MalformedFixture(
        "credential-not-string", line: 2, key: "linear.credential",
        .typeMismatch(expected: "string", found: "integer")
    ),
    MalformedFixture(
        "fallbacks-not-array", line: 9, key: "routing[0].fallbacks",
        .typeMismatch(expected: "array", found: "string")
    ),
    MalformedFixture(
        "routing-not-array-of-tables", line: 7, key: "routing",
        .typeMismatch(expected: "array of tables", found: "table")
    ),
    MalformedFixture(
        "cli-adapter-not-table", line: 8, key: "cli.claude",
        .typeMismatch(expected: "table", found: "string")
    ),
    MalformedFixture("unknown-top-level-key", line: 2, key: "schedule", .unknownKey),
    MalformedFixture("unknown-linear-key", line: 3, key: "linear.workspace", .unknownKey),
    MalformedFixture("unknown-cli-key", line: 8, key: "cli.claude.executible", .unknownKey),
    MalformedFixture("unknown-routing-entry-key", line: 8, key: "routing[0].repo-role", .unknownKey),
    MalformedFixture("unknown-route-table-key", line: 8, key: "routing[0].route.efort", .unknownKey)
]

private let routingFixtures: [MalformedFixture] = [
    MalformedFixture("kind-empty-segment", line: 8, key: "routing[0].kind", .invalidKind("impl..x")),
    MalformedFixture("kind-empty", line: 8, key: "routing[0].kind", .invalidKind("")),
    MalformedFixture("kind-star-in-path", line: 8, key: "routing[0].kind", .invalidKind("impl.*")),
    MalformedFixture("repo-role-empty", line: 8, key: "routing[0].repo_role", .emptyString),
    MalformedFixture("route-missing", line: 10, key: "routing[1].route", .missingKey),
    MalformedFixture("route-one-part", line: 8, key: "routing[0].route", .invalidRoute("claude")),
    MalformedFixture("route-four-parts", line: 8, key: "routing[0].route", .invalidRoute("claude/sonnet/high/extra")),
    MalformedFixture("route-empty-part", line: 8, key: "routing[0].route", .invalidRoute("claude//high")),
    MalformedFixture("route-table-missing-cli", line: 8, key: "routing[0].route.cli", .missingKey),
    MalformedFixture("route-subtable-missing-model", line: 10, key: "routing[0].route.model", .missingKey),
    MalformedFixture("route-table-empty-cli", line: 8, key: "routing[0].route.cli", .emptyString),
    MalformedFixture("fallback-empty-string", line: 9, key: "routing[0].fallbacks[1]", .invalidRoute("")),
    MalformedFixture("duplicate-routing-entry", line: 12, key: "routing[1]", .duplicateRoutingEntry(firstLine: 7)),
    // Every route must name a declared CLI Adapter (routing/add-an-agent-cli).
    MalformedFixture("route-undeclared-cli", line: 10, key: "routing[0].route", .undeclaredCLIAdapter("gemini")),
    MalformedFixture(
        "fallback-undeclared-cli", line: 11, key: "routing[0].fallbacks[1]", .undeclaredCLIAdapter("gemini")
    ),
    MalformedFixture("routing-without-cli-table", line: 8, key: "routing[0].route", .undeclaredCLIAdapter("claude"))
]

@Test(
    "Each malformed file is reported with its file, line and key",
    arguments: syntaxFixtures + shapeFixtures + routingFixtures
)
func malformedFixture(_ fixture: MalformedFixture) throws {
    let url = try #require(
        Bundle.module.url(forResource: fixture.name, withExtension: "toml", subdirectory: "Fixtures/Malformed")
    )
    do {
        _ = try MachineConfiguration.load(contentsOf: url)
        Issue.record("expected \(fixture.name) to fail")
    } catch {
        #expect(error.file == url.path(percentEncoded: false))
        #expect(error.line == fixture.line, "\(error)")
        #expect(error.key == fixture.key, "\(error)")
        if let reason = fixture.reason {
            #expect(error.reason == reason, "\(error)")
        } else if case .syntax = error.reason {
            // Any syntax message will do.
        } else {
            Issue.record("expected a syntax error, got \(error)")
        }
    }
}
