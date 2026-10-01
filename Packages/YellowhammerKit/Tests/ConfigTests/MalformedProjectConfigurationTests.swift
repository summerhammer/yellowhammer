import Config
import Domain
import Foundation
import Testing

private let identityFixtures: [MalformedFixture] = [
    MalformedFixture("missing-id", line: 1, key: "id", .missingKey),
    MalformedFixture("invalid-project-id", line: 1, key: "id", .invalidProjectID("invalid@id!")),
    MalformedFixture("non-ascii-project-id", line: 1, key: "id", .invalidProjectID("café")),
    MalformedFixture("mismatch", line: 1, key: "id", .projectIDMismatch(fileStem: "mismatch")),
    MalformedFixture("missing-name", line: 1, key: "name", .missingKey),
    MalformedFixture("missing-linear-project", line: 1, key: "linear_project", .missingKey),
    MalformedFixture("unknown-top-key", line: 4, key: "unknown_key", .unknownKey)
]

private let repoFixtures: [MalformedFixture] = [
    MalformedFixture("missing-repos", line: 1, key: "repos", .missingKey),
    MalformedFixture("empty-repos", line: 4, key: "repos", .emptyArray),
    MalformedFixture("missing-repo-name", line: 5, key: "repos[0].name", .missingKey),
    MalformedFixture("missing-repo-path", line: 5, key: "repos[0].path", .missingKey),
    MalformedFixture("missing-repo-role", line: 5, key: "repos[0].role", .missingKey),
    MalformedFixture("missing-check", line: 5, key: "repos[0].check", .missingKey),
    MalformedFixture("empty-check", line: 9, key: "repos[0].check", .emptyString),
    MalformedFixture(
        "check-not-string", line: 9, key: "repos[0].check",
        .typeMismatch(expected: "string", found: "integer")
    ),
    MalformedFixture("duplicate-repo-name", line: 11, key: "repos[1].name", .duplicateRepo(firstLine: 5)),
    MalformedFixture(
        "protected-paths-not-array", line: 10, key: "repos[0].protected_paths",
        .typeMismatch(expected: "array", found: "string")
    ),
    MalformedFixture(
        "protected-path-not-string", line: 10, key: "repos[0].protected_paths[1]",
        .typeMismatch(expected: "string", found: "integer")
    ),
    MalformedFixture("unknown-repo-key", line: 10, key: "repos[0].unknown_field", .unknownKey)
]

private let limitsAndScheduleFixtures: [MalformedFixture] = [
    MalformedFixture("bounds-zero", line: 12, key: "limits.unanswered_nights_max", .notPositive(0)),
    MalformedFixture("bounds-negative", line: 12, key: "limits.attempts_per_card", .notPositive(-1)),
    MalformedFixture(
        "limit-not-integer", line: 12, key: "limits.review_rounds_max",
        .typeMismatch(expected: "integer", found: "string")
    ),
    MalformedFixture("unknown-limits-key", line: 12, key: "limits.unknown_bound", .unknownKey),
    MalformedFixture("build-every-zero", line: 12, key: "schedule.build_every_minutes", .notPositive(0)),
    MalformedFixture("invalid-time-hour", line: 12, key: "schedule.night_start", .invalidTimeOfDay("25:00")),
    MalformedFixture("invalid-time-format", line: 12, key: "schedule.night_end", .invalidTimeOfDay("9:00")),
    MalformedFixture("unknown-schedule-key", line: 12, key: "schedule.weird_time", .unknownKey)
]

private let credentialAndRoutingFixtures: [MalformedFixture] = [
    MalformedFixture("unknown-github-key", line: 13, key: "github.unknown_key", .unknownKey),
    MalformedFixture("routing-invalid-route", line: 12, key: "routing[0].route", .invalidRoute("invalid")),
    MalformedFixture("routing-duplicate", line: 15, key: "routing[1]", .duplicateRoutingEntry(firstLine: 11)),
    MalformedFixture(
        "routing-authoring-repo-role", line: 13, key: "routing[0].repo_role",
        .reservedKindNamesRepoRole(kind: "authoring")
    )
]

/// Exactly one specification source across both kinds, and a Spec Source is a path only. The other
/// per-file rules of P2.3 are covered above: `missing-check` (an absent `check` is refused, never
/// read as `none`) and `bounds-zero` (`unanswered_nights_max` must be an integer >= 1).
private let specificationSourceFixtures: [MalformedFixture] = [
    MalformedFixture("no-spec-source", line: 1, key: nil, .noSpecificationSource),
    MalformedFixture("two-spec-repos", line: 14, key: "repos[1].role", .secondSpecificationSource(firstLine: 8)),
    MalformedFixture(
        "spec-source-and-spec-repo", line: 9, key: "repos[0].role", .secondSpecificationSource(firstLine: 4)
    ),
    MalformedFixture(
        "spec-source-table", line: 11, key: "spec_source", .typeMismatch(expected: "string", found: "table")
    )
]

@Test(
    "Each malformed Project file is reported with its file, line and key",
    arguments: identityFixtures + repoFixtures + limitsAndScheduleFixtures + credentialAndRoutingFixtures
        + specificationSourceFixtures
)
func malformedProjectFixture(_ fixture: MalformedFixture) throws {
    let url = try #require(
        Bundle.module.url(forResource: fixture.name, withExtension: "toml", subdirectory: "Fixtures/Projects/Malformed")
    )
    do {
        let configuration = try ProjectConfiguration.load(contentsOf: url)
        Issue.record("expected \(fixture.name) to fail, loaded \(configuration)")
    } catch {
        #expect(error.file == url.path(percentEncoded: false))
        #expect(error.line == fixture.line, "\(error)")
        #expect(error.key == fixture.key, "\(error)")
        #expect(error.reason == fixture.reason, "\(error)")
    }
}

@Test("parse does not compare the id with a file name")
func parseSkipsFileStemCheck() throws {
    let text = """
    id = "anything"
    name = "Anything"
    linear_project = "ANY"
    spec_source = "~/spec"

    [[repos]]
    name = "repo"
    path = "~/path"
    role = "backend"
    check = "none"
    """
    let configuration = try ProjectConfiguration.parse(text, file: "/tmp/other-name.toml")
    #expect(configuration.id.rawValue == "anything")
    #expect(configuration.repos.first?.check == Check.none)
}

private let overrideText = """
id = "override"
name = "Override"
linear_project = "OVR"
spec_source = "~/spec"

[[repos]]
name = "repo"
path = "~/path"
role = "backend"
check = "none"

[[routing]]
kind = "review"
route = "claude/opus"
fallbacks = ["gemini/pro"]
"""

@Test("A Routing Table override naming a CLI with no adapter is refused only when the adapters are known")
func overrideAdapterCheckNeedsTheDeclaredAdapters() throws {
    let unchecked = try ProjectConfiguration.parse(overrideText, file: "/tmp/override.toml")
    #expect(unchecked.routingOverrides.count == 1)

    let checked = Result { () throws(ConfigurationError) in
        try ProjectConfiguration.parse(overrideText, file: "/tmp/override.toml", declaredCLIAdapters: ["claude"])
    }
    guard case .failure(let error) = checked else {
        Issue.record("expected the override to be refused")
        return
    }
    #expect(error.line == 15)
    #expect(error.key == "routing[0].fallbacks[0]")
    #expect(error.reason == .undeclaredCLIAdapter("gemini"))
}
