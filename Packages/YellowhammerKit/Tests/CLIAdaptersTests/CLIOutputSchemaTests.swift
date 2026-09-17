@testable import CLIAdapters
import Domain
import Foundation
import Testing

/// Covers ``CLIOutputSchema`` — the strict-structured-outputs dialect ``ResultSchema`` is rendered
/// into for the CLIs, derived after live runs against `claude` and `codex` rejected the Domain
/// document as-is (P7.3 follow-up).
@Suite("CLIOutputSchema")
struct CLIOutputSchemaTests {
    private static let forbiddenTopLevelKeywords = ["$schema", "oneOf", "if", "then", "else", "allOf", "anyOf"]

    /// The property each pass leaves optional in ``ResultSchema`` (absent from `required`), used to
    /// prove strict mode makes it nullable rather than dropping it.
    private static func optionalProperty(for pass: RunPass) -> String {
        switch pass {
        case .architect: "reason"
        case .worker: "commit"
        case .reviewer: "requested_changes"
        }
    }

    @Test("Every pass's strict schema drops the conditional/2020-12-only keywords", arguments: RunPass.allCases)
    func dropsForbiddenTopLevelKeywords(pass: RunPass) throws {
        let object = try Self.parse(Data(CLIOutputSchema.strict(for: pass).utf8))
        for keyword in Self.forbiddenTopLevelKeywords {
            #expect(object[keyword] == nil, "unexpected top-level `\(keyword)` in \(pass) strict schema")
        }
    }

    @Test("Every pass's strict schema requires every declared property", arguments: RunPass.allCases)
    func requiresEveryProperty(pass: RunPass) throws {
        let object = try Self.parse(Data(CLIOutputSchema.strict(for: pass).utf8))
        let properties = try #require(object["properties"] as? [String: Any])
        let required = try #require(object["required"] as? [String])
        #expect(Set(required) == Set(properties.keys))
    }

    @Test("Every pass's strict schema forbids additional properties", arguments: RunPass.allCases)
    func forbidsAdditionalProperties(pass: RunPass) throws {
        let object = try Self.parse(Data(CLIOutputSchema.strict(for: pass).utf8))
        #expect(object["additionalProperties"] as? Bool == false)
    }

    @Test("A Domain-optional property becomes nullable: type is [<t>, \"null\"]", arguments: RunPass.allCases)
    func optionalPropertyIsNullable(pass: RunPass) throws {
        let object = try Self.parse(Data(CLIOutputSchema.strict(for: pass).utf8))
        let properties = try #require(object["properties"] as? [String: Any])
        let property = try #require(properties[Self.optionalProperty(for: pass)] as? [String: Any])
        let type = try #require(property["type"] as? [String])
        #expect(type.count == 2)
        #expect(type.last == "null")
    }

    @Test("The `schema` property is a one-value enum naming the pass's schema identifier", arguments: RunPass.allCases)
    func schemaPropertyIsASingleValueEnum(pass: RunPass) throws {
        let object = try Self.parse(Data(CLIOutputSchema.strict(for: pass).utf8))
        let properties = try #require(object["properties"] as? [String: Any])
        let schemaProperty = try #require(properties["schema"] as? [String: Any])
        let values = try #require(schemaProperty["enum"] as? [String])
        #expect(values == [pass.schemaIdentifier])
    }

    // MARK: - Round trip: a strict-mode CLI output, nulls stripped, still decodes

    @Test("A strict-mode worker output, with its nullable fields null, decodes after removingNullMembers")
    func workerRoundTrip() throws {
        let json = """
            {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
            "commit":"0123456789abcdef0123456789abcdef01234567","summary":"s",\
            "question":null,"reason":null}
            """
        let normalized = try #require(CLIOutputSchema.removingNullMembers(from: Data(json.utf8)))
        let object = try Self.parse(normalized)
        #expect(object["question"] == nil)
        #expect(object["reason"] == nil)

        let result = try ResultFile.decode(normalized, expecting: .worker)
        guard case .worker(let worker) = result else {
            Issue.record("expected .worker(_), got \(result)")
            return
        }
        #expect(worker.outcome == .completed(commit: "0123456789abcdef0123456789abcdef01234567", summary: "s"))
    }

    @Test("A strict-mode reviewer approval, with requested_changes null, decodes after removingNullMembers")
    func reviewerRoundTrip() throws {
        let json = """
            {"schema":"yellowhammer.result.reviewer","version":1,"verdict":"approved",\
            "judged_commit":"0123456789abcdef0123456789abcdef01234567","summary":"s",\
            "requested_changes":null}
            """
        let normalized = try #require(CLIOutputSchema.removingNullMembers(from: Data(json.utf8)))
        let object = try Self.parse(normalized)
        #expect(object["requested_changes"] == nil)

        let result = try ResultFile.decode(normalized, expecting: .reviewer)
        guard case .reviewer(let reviewer) = result else {
            Issue.record("expected .reviewer(_), got \(result)")
            return
        }
        guard case .approved(let judgedCommit, let summary) = reviewer.outcome else {
            Issue.record("expected .approved, got \(reviewer.outcome)")
            return
        }
        #expect(judgedCommit == "0123456789abcdef0123456789abcdef01234567")
        #expect(summary == "s")
    }

    // MARK: - Helpers

    private static func parse(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }
}
