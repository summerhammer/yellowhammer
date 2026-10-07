import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear issues read")
struct LinearIssuesTests {
    private static let issueNodes = """
        {"id":"issue-1","identifier":"ENG-123","title":"Add the thing","description":"Body",
         "url":"https://linear.app/acme/issue/ENG-123","createdAt":"2026-09-01T10:00:00.000Z",
         "updatedAt":"2026-09-15T22:30:15.250Z","state":{"id":"state-1","name":"Waiting on You"},
         "labels":{"nodes":[{"name":"yh:card"},{"name":"backend"}]},"parent":{"id":"feature-1"}},
        {"id":"feature-1","identifier":"ENG-100","title":"Feature","description":null,
         "url":"https://linear.app/acme/issue/ENG-100","createdAt":"2026-08-30T08:00:00Z",
         "updatedAt":"2026-09-14T08:00:00Z","state":{"id":"state-2","name":"In Progress"},
         "labels":{"nodes":[]},"parent":null}
        """

    @Test("The Linear project id is in the filter even when updatedSince is nil, and alone")
    func linearProjectScopeWithoutUpdatedSince() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.issues()])
        _ = try await Fixture.adapter(transport).objects(updatedSince: nil)

        let variables = try Fixture.variables(transport.requests[1])
        let filter = try #require(variables["filter"] as? [String: Any])
        #expect(Set(filter.keys) == [Fixture.scopeKey])
        let scope = try #require(filter[Fixture.scopeKey] as? [String: Any])
        let id = try #require(scope["id"] as? [String: Any])
        #expect(id["eq"] as? String == Fixture.linearProjectID)
        #expect(variables["projectId"] as? String == Fixture.linearProjectID)
        #expect(variables["first"] as? Int == 200)
        #expect(variables["after"] == nil)
    }

    @Test("updatedSince adds an updatedAt.gt clause beside the Linear project scope")
    func updatedSinceAddsClause() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.issues()])
        let since = Date(timeIntervalSince1970: 1_789_000_000.5)
        _ = try await Fixture.adapter(transport).objects(updatedSince: since, after: nil, pageSize: 50)

        let variables = try Fixture.variables(transport.requests[1])
        let filter = try #require(variables["filter"] as? [String: Any])
        #expect(Set(filter.keys) == [Fixture.scopeKey, "updatedAt"])
        let scope = try #require(filter[Fixture.scopeKey] as? [String: Any])
        #expect((scope["id"] as? [String: Any])?["eq"] as? String == Fixture.linearProjectID)
        let updatedAt = try #require(filter["updatedAt"] as? [String: Any])
        let gt = try #require(updatedAt["gt"] as? String)
        #expect(gt == "2026-09-10T00:26:40.500Z")
        #expect(variables["first"] as? Int == 50)
    }

    @Test("A page of Linear issues decodes into board objects")
    func pageDecodes() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.issues(nodes: Self.issueNodes)])
        let page = try await Fixture.adapter(transport).objects(updatedSince: nil)

        #expect(page.objects.count == 2)
        let card = try #require(page.objects.first)
        #expect(card.id == BoardObjectID(rawValue: "issue-1"))
        #expect(card.key == "ENG-123")
        #expect(card.title == "Add the thing")
        #expect(card.description == "Body")
        #expect(card.workflowState.id == BoardObjectID(rawValue: "state-1"))
        #expect(card.workflowState.name == "Waiting on You")
        #expect(card.labels == ["yh:card", "backend"])
        #expect(card.parent == BoardObjectID(rawValue: "feature-1"))
        #expect(card.url == "https://linear.app/acme/issue/ENG-123")
        #expect(card.createdAt == Date(timeIntervalSince1970: 1_788_256_800))
        #expect(card.updatedAt == Date(timeIntervalSince1970: 1_789_511_415.25))

        let feature = page.objects[1]
        #expect(feature.description == nil)
        #expect(feature.parent == nil)
        #expect(feature.labels.isEmpty)
        #expect(feature.updatedAt == Date(timeIntervalSince1970: 1_789_372_800))
        #expect(page.nextCursor == nil)
    }

    @Test("A state's vendor type 'canceled' decodes to the shelved category")
    func shelvedCategoryDecodes() async throws {
        let nodes = """
            {"id":"issue-1","identifier":"ENG-123","title":"Add the thing","description":"Body",
             "url":"https://linear.app/acme/issue/ENG-123","createdAt":"2026-09-01T10:00:00.000Z",
             "updatedAt":"2026-09-15T22:30:15.250Z",
             "state":{"id":"state-1","name":"Canceled","type":"canceled"},
             "labels":{"nodes":[]},"parent":null}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.issues(nodes: nodes)])
        let page = try await Fixture.adapter(transport).objects(updatedSince: nil)

        let card = try #require(page.objects.first)
        #expect(card.workflowState.name == "Canceled")
        #expect(card.workflowState.category == .shelved)
        #expect(card.workflowState.isShelved)
    }

    @Test("The issues query requests the workflow state's vendor type")
    func issuesQueryRequestsType() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.issues()])
        _ = try await Fixture.adapter(transport).objects(updatedSince: nil)

        let body = try Fixture.body(transport.requests[1])
        let query = try #require(body["query"] as? String)
        #expect(query.contains("state { id name type }"))
    }

    @Test("hasNextPage drives nextCursor, and the cursor is sent back as after")
    func cursorRoundTrips() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.issues(hasNextPage: true, endCursor: "cursor-abc"),
            Fixture.issues(hasNextPage: false, endCursor: "cursor-def")
        ])
        let adapter = Fixture.adapter(transport)

        let first = try await adapter.objects(updatedSince: nil)
        #expect(first.nextCursor == BoardCursor(rawValue: "cursor-abc"))
        let second = try await adapter.objects(updatedSince: nil, after: first.nextCursor)
        #expect(second.nextCursor == nil)

        #expect(try Fixture.variables(transport.requests[2])["after"] as? String == "cursor-abc")
    }
}
