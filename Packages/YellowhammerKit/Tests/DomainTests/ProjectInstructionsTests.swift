import Domain
import Foundation
import Testing

@Suite("Project instructions domain rules")
struct ProjectInstructionsTests {
    @Test("Exactly 32,768 bytes is accepted and 32,769 is rejected with the count")
    func byteBoundary() {
        #expect(ProjectInstructions.validate(String(repeating: "a", count: 32_768)) == .accepted(byteCount: 32_768))
        #expect(ProjectInstructions.validate(String(repeating: "a", count: 32_769)) == .tooLarge(byteCount: 32_769))
    }

    @Test("Whitespace and line breaks count toward the limit")
    func whitespaceCounts() {
        let text = String(repeating: "\n", count: 32_769)
        #expect(ProjectInstructions.validate(text) == .tooLarge(byteCount: 32_769))
    }

    @Test("A multibyte text under the limit in characters but over it in bytes is rejected")
    func multibyte() {
        let text = String(repeating: "é", count: 20_000)
        #expect(text.count < 32_768)
        #expect(ProjectInstructions.validate(text) == .tooLarge(byteCount: 40_000))
    }

    @Test("Empty means blank after trimming")
    func emptiness() {
        #expect(ProjectInstructions.isEmpty(""))
        #expect(ProjectInstructions.isEmpty(" \n\t "))
        #expect(!ProjectInstructions.isEmpty(" a "))
    }

    @Test("Production default versions cover exactly the six accepting families")
    func productionVersions() {
        let versions = PromptFamily.productionDefaultVersions
        #expect(Set(versions.keys) == Set(PromptFamily.allCases.filter(\.acceptsProjectInstructions)))
        #expect(versions.count == 6)
    }

    private func revision(_ versions: [PromptFamily: Int]) -> ProjectInstructionsRevision {
        ProjectInstructionsRevision(
            id: "r1", text: "t", savedAt: Date(timeIntervalSince1970: 0), reviewedDefaultVersions: versions
        )
    }

    @Test("No default changes when reviewed versions match")
    func noChanges() {
        #expect(revision(PromptFamily.productionDefaultVersions).defaultChanges().isEmpty)
    }

    @Test("A simulated bump reports changed and missing families in allCases order")
    func simulatedBump() {
        var reviewed = PromptFamily.productionDefaultVersions
        reviewed[.reviewer] = nil
        var current = PromptFamily.productionDefaultVersions
        current[.breakdown] = 2
        current[.reviewer] = 1
        let changes = revision(reviewed).defaultChanges(current: current)
        #expect(changes == [
            ProjectInstructionsDefaultChange(family: .breakdown, reviewedVersion: 1, currentVersion: 2),
            ProjectInstructionsDefaultChange(family: .reviewer, reviewedVersion: nil, currentVersion: 1)
        ])
    }

    @Test("A revision round-trips through JSON with stable string keys")
    func roundTrip() throws {
        let original = revision(PromptFamily.productionDefaultVersions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let versions = try #require(object["reviewedDefaultVersions"] as? [String: Int])
        #expect(versions["worker"] == 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ProjectInstructionsRevision.self, from: data) == original)
    }

    @Test("Records written before the unavailable case still decode, and the new case round-trips")
    func useDecoding() throws {
        let decoder = JSONDecoder()
        let absent = Data(#"{"absent":{}}"#.utf8)
        let revision = Data(#"{"revision":{"_0":"rev-1"}}"#.utf8)
        #expect(try decoder.decode(ProjectInstructionsUse.self, from: absent) == .absent)
        #expect(try decoder.decode(ProjectInstructionsUse.self, from: revision) == .revision("rev-1"))
        let unavailable = ProjectInstructionsUse.unavailable(cause: "bad")
        let data = try JSONEncoder().encode(unavailable)
        #expect(try decoder.decode(ProjectInstructionsUse.self, from: data) == unavailable)
    }
}
