import Domain
import Foundation
import Testing

// P7.1: result schema and instruction contract

@Test("Each pass's JSON Schema parses and requires schema, version and its discriminator", arguments: RunPass.allCases)
func jsonSchemaParsesAndRequiresEnvelopeFields(_ pass: RunPass) throws {
    let data = ResultSchema.schemaData(for: pass)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["additionalProperties"] as? Bool == false)

    let required = try #require(object["required"] as? [String])
    #expect(required.contains("schema"))
    #expect(required.contains("version"))
    let discriminator = pass == .reviewer ? "verdict" : "outcome"
    #expect(required.contains(discriminator))

    let properties = try #require(object["properties"] as? [String: Any])
    let schemaProperty = try #require(properties["schema"] as? [String: Any])
    #expect(schemaProperty["const"] as? String == pass.schemaIdentifier)

    let versionProperty = try #require(properties["version"] as? [String: Any])
    #expect(versionProperty["const"] as? Int == 1)
}

@Test("jsonSchema(for:) matches schemaData(for:)", arguments: RunPass.allCases)
func jsonSchemaMatchesSchemaData(_ pass: RunPass) {
    #expect(ResultSchema.schemaData(for: pass) == Data(ResultSchema.jsonSchema(for: pass).utf8))
}

@Test("WorkerResult round-trips through Codable for every outcome")
func workerResultRoundTripsThroughCodable() throws {
    let outcomes: [WorkerOutcome] = [
        .completed(commit: String(repeating: "a", count: 40), summary: "done"),
        .question("what now?"),
        .failed(reason: "check failed")
    ]
    for outcome in outcomes {
        let original = WorkerResult(outcome: outcome)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorkerResult.self, from: data)
        #expect(decoded == original)
    }
}

@Test("ArchitectResult round-trips through Codable for every outcome")
func architectResultRoundTripsThroughCodable() throws {
    let outcomes: [ArchitectOutcome] = [
        .planned(plan: "do the thing", affectedPaths: ["a.swift", "b.swift"]),
        .failed(reason: "no repos configured")
    ]
    for outcome in outcomes {
        let original = ArchitectResult(outcome: outcome)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ArchitectResult.self, from: data)
        #expect(decoded == original)
    }
}

@Test("ReviewerResult round-trips through Codable for every outcome")
func reviewerResultRoundTripsThroughCodable() throws {
    let commit = String(repeating: "a", count: 40)
    let outcomes: [ReviewerOutcome] = [
        .approved(judgedCommit: commit, summary: "looks good"),
        .changesRequested(judgedCommit: commit, summary: "not quite", requestedChanges: ["fix x"])
    ]
    for outcome in outcomes {
        let original = ReviewerResult(outcome: outcome)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReviewerResult.self, from: data)
        #expect(decoded == original)
    }
}
