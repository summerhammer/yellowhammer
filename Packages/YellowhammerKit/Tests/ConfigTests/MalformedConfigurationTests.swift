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

private let acmeCredential = "board.linear.connections.acme.credential"

private let syntaxFixtures: [MalformedFixture] = [
    MalformedFixture("syntax-unterminated-string", line: 2, key: acmeCredential),
    MalformedFixture("syntax-bad-value", line: 2, key: acmeCredential),
    MalformedFixture("syntax-missing-equals", line: 2, key: acmeCredential),
    MalformedFixture("syntax-invalid-escape", line: 4, key: acmeCredential),
    MalformedFixture("syntax-stray-character", line: 2, key: nil),
    MalformedFixture("syntax-bad-array-element", line: 10, key: "routing[0].fallbacks[1]"),
    MalformedFixture("syntax-inline-table-trailing-comma", line: 7, key: "routing[0].route"),
    MalformedFixture("duplicate-key", line: 3, key: acmeCredential, .duplicateKey(firstLine: 2)),
    MalformedFixture("table-redefined", line: 6, key: "board.linear.connections.acme", .tableRedefined(firstLine: 1))
]

private let shapeFixtures: [MalformedFixture] = [
    // The old single `[linear]` shape is refused as an unknown key, with no migration and no named error.
    MalformedFixture("top-level-linear", line: 1, key: "linear", .unknownKey),
    MalformedFixture("board-linear-flat-credential", line: 2, key: "board.linear.credential", .unknownKey),
    MalformedFixture("board-linear-installation-key", line: 2, key: "board.linear.installation", .unknownKey),
    MalformedFixture("board-unknown-vendor", line: 1, key: "board.jira", .unknownKey),
    MalformedFixture(
        "duplicate-linear-workspace", line: 8, key: "board.linear.connections.beta.workspace",
        .duplicateLinearWorkspace(firstInstallation: "acme", firstLine: 3)
    ),
    MalformedFixture(
        "installation-missing-credential", line: 2, key: "board.linear.connections.acme.credential", .missingKey
    ),
    MalformedFixture(
        "installation-missing-workspace", line: 2, key: "board.linear.connections.acme.workspace", .missingKey
    ),
    MalformedFixture(
        "installation-missing-app-user", line: 2,
        key: "board.linear.connections.acme.yellowhammer_identity", .missingKey
    ),
    MalformedFixture(
        "installation-unknown-key", line: 4, key: "board.linear.connections.acme.client_id", .unknownKey
    ),
    MalformedFixture("installation-empty-name", line: 1, key: "board.linear.connections.\"\"", .emptyString),
    MalformedFixture("missing-github-credential", line: 3, key: "github.credential", .missingKey),
    MalformedFixture("empty-credential", line: 4, key: "github.credential", .emptyString),
    MalformedFixture(
        "credential-not-string", line: 2, key: acmeCredential,
        .typeMismatch(expected: "string", found: "integer")
    ),
    MalformedFixture(
        "fallbacks-not-array", line: 8, key: "routing[0].fallbacks",
        .typeMismatch(expected: "array", found: "string")
    ),
    MalformedFixture(
        "routing-not-array-of-tables", line: 6, key: "routing",
        .typeMismatch(expected: "array of tables", found: "table")
    ),
    MalformedFixture(
        "cli-adapter-not-table", line: 7, key: "cli.claude",
        .typeMismatch(expected: "table", found: "string")
    ),
    MalformedFixture("unknown-top-level-key", line: 2, key: "schedule", .unknownKey),
    MalformedFixture("unknown-cli-key", line: 7, key: "cli.claude.executible", .unknownKey),
    MalformedFixture("unknown-routing-entry-key", line: 7, key: "routing[0].repo-role", .unknownKey),
    MalformedFixture("unknown-route-table-key", line: 7, key: "routing[0].route.efort", .unknownKey)
]

private let routingFixtures: [MalformedFixture] = [
    MalformedFixture("kind-empty-segment", line: 7, key: "routing[0].work_kind", .invalidKind("impl..x")),
    MalformedFixture("kind-empty", line: 7, key: "routing[0].work_kind", .invalidKind("")),
    MalformedFixture("kind-star-in-path", line: 7, key: "routing[0].work_kind", .invalidKind("impl.*")),
    MalformedFixture("repo-role-empty", line: 7, key: "routing[0].repo_role", .emptyString),
    MalformedFixture("route-missing", line: 9, key: "routing[1].route", .missingKey),
    MalformedFixture("route-one-part", line: 7, key: "routing[0].route", .invalidRoute("claude")),
    MalformedFixture("route-four-parts", line: 7, key: "routing[0].route", .invalidRoute("claude/sonnet/high/extra")),
    MalformedFixture("route-empty-part", line: 7, key: "routing[0].route", .invalidRoute("claude//high")),
    MalformedFixture("route-table-missing-cli", line: 7, key: "routing[0].route.cli", .missingKey),
    MalformedFixture("route-subtable-missing-model", line: 9, key: "routing[0].route.model", .missingKey),
    MalformedFixture("route-table-empty-cli", line: 7, key: "routing[0].route.cli", .emptyString),
    MalformedFixture("fallback-empty-string", line: 8, key: "routing[0].fallbacks[1]", .invalidRoute("")),
    MalformedFixture("duplicate-routing-entry", line: 11, key: "routing[1]", .duplicateRoutingEntry(firstLine: 6)),
    // Every route must name a declared CLI Adapter (routing/add-an-agent-cli).
    MalformedFixture("route-undeclared-cli", line: 9, key: "routing[0].route", .undeclaredCLIAdapter("gemini")),
    MalformedFixture(
        "fallback-undeclared-cli", line: 10, key: "routing[0].fallbacks[1]", .undeclaredCLIAdapter("gemini")
    ),
    // The author Act resolves with no Repo Role, so a reserved-Kind entry naming one could never match.
    MalformedFixture(
        "authoring-with-repo-role", line: 8, key: "routing[0].repo_role",
        .reservedKindNamesRepoRole(kind: "authoring")
    ),
    MalformedFixture("routing-without-cli-table", line: 7, key: "routing[0].route", .undeclaredCLIAdapter("claude"))
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
