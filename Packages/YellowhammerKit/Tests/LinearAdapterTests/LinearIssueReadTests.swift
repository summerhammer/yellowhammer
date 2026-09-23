import Domain
import Foundation
import LinearAdapter
import Testing

// The settle gesture's single-issue read (roadmap P10.9): a targeted `issue(id:)` query, decoded the
// same way a page of issues is.

@Suite("Linear single-issue read")
struct LinearIssueReadTests {
    private static let issueNode = """
        {"id":"feature-1","identifier":"ENG-100","title":"Feature","description":"Body",
         "url":"https://linear.app/acme/issue/ENG-100","createdAt":"2026-08-30T08:00:00Z",
         "updatedAt":"2026-09-14T08:00:00Z","state":{"id":"state-2","name":"Released"},
         "labels":{"nodes":[{"name":"yh:feature"}]},"parent":null}
        """

    private static func issueReply(_ node: String?) -> StubHTTPTransport.Reply {
        Fixture.json(#"{"data":{"issue":\#(node ?? "null")}}"#)
    }

    @Test("A single issue decodes into a board object")
    func issueDecodes() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Self.issueReply(Self.issueNode)])
        let object = try await Fixture.adapter(transport).issue(BoardObjectID(rawValue: "feature-1"))

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["id"] as? String == "feature-1")

        let feature = try #require(object)
        #expect(feature.id == BoardObjectID(rawValue: "feature-1"))
        #expect(feature.key == "ENG-100")
        #expect(feature.title == "Feature")
        #expect(feature.description == "Body")
        #expect(feature.workflowState.id == BoardObjectID(rawValue: "state-2"))
        #expect(feature.workflowState.name == "Released")
        #expect(feature.labels == ["yh:feature"])
        #expect(feature.parent == nil)
        #expect(feature.url == "https://linear.app/acme/issue/ENG-100")
    }

    @Test("A missing issue decodes to nil")
    func missingIssueDecodesToNil() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Self.issueReply(nil)])
        let object = try await Fixture.adapter(transport).issue(BoardObjectID(rawValue: "not-there"))
        #expect(object == nil)
    }
}
