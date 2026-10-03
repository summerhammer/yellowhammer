import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear workspace members and teams")
struct LinearWorkspaceProvisioningTests {
    @Test("Decoding a user node carries active, app and isMe as the Board's flags")
    func userNodeDecodes() async throws {
        let json = """
            {"data":{"users":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
              {"id":"user-1","name":"alice","displayName":"Alice","active":true,"app":false,"isMe":false},
              {"id":"user-2","name":"bot","displayName":"Bot","active":true,"app":true,"isMe":false},
              {"id":"user-3","name":"yellowhammer","displayName":"Yellowhammer","active":true,"app":false,
               "isMe":true},
              {"id":"user-4","name":"carol","displayName":"Carol","active":false,"app":false,"isMe":false}
            ]}}}
            """
        let transport = StubHTTPTransport([Fixture.token(), Fixture.json(json)])
        let adapter = Fixture.adapter(transport)

        let members = try await adapter.workspaceMembers()

        #expect(members.count == 4)
        #expect(members[0] == BoardMember(
            id: BoardObjectID(rawValue: "user-1"), name: "alice", displayName: "Alice",
            isActive: true, isApp: false, isSelf: false
        ))
        #expect(members[1].isApp)
        #expect(members[2].isSelf)
        #expect(!members[3].isActive)
    }

    @Test("The users query carries includeDisabled: true and paginates")
    func usersQueryIncludesDisabledAndPaginates() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"users":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-a"},"nodes":[
                  {"id":"user-1","name":"alice","displayName":"Alice","active":true,"app":false,"isMe":false}
                ]}}}
                """),
            Fixture.json("""
                {"data":{"users":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"id":"user-2","name":"bob","displayName":"Bob","active":true,"app":false,"isMe":false}
                ]}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        let members = try await adapter.workspaceMembers()

        #expect(members.count == 2)
        let body = try Fixture.body(transport.requests[1])
        let query = try #require(body["query"] as? String)
        #expect(query.contains("includeDisabled: true"))
        #expect(try Fixture.variables(transport.requests[2])["after"] as? String == "cursor-a")
    }

    @Test("Teams decode id, key and name, and paginate")
    func teamsDecodeAndPaginate() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"teams":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-a"},"nodes":[
                  {"id":"team-1","key":"ENG","name":"Engineering"}
                ]}}}
                """),
            Fixture.json("""
                {"data":{"teams":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"id":"team-2","key":"PRD","name":"Product"}
                ]}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        let teams = try await adapter.teams()

        #expect(teams.count == 2)
        #expect(teams[0] == BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering"))
        #expect(teams[1] == BoardTeam(id: BoardObjectID(rawValue: "team-2"), key: "PRD", name: "Product"))
        #expect(try Fixture.variables(transport.requests[2])["after"] as? String == "cursor-a")
    }

    @Test("Linear projects decode teams and the completed/canceled flags, and paginate") // glossary:ignore GL001
    func linearProjectsDecodeFlagsAndPaginate() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("""
                {"data":{"projects":{"pageInfo":{"hasNextPage":true,"endCursor":"cursor-a"},"nodes":[
                  {"id":"p1","name":"Active","completedAt":null,"canceledAt":null,
                   "teams":{"nodes":[{"id":"team-1","key":"ENG","name":"Engineering"}]}},
                  {"id":"p2","name":"Done","completedAt":"2026-01-01T00:00:00.000Z","canceledAt":null,
                   "teams":{"nodes":[]}}
                ]}}}
                """),
            Fixture.json("""
                {"data":{"projects":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                  {"id":"p3","name":"Dropped","completedAt":null,"canceledAt":"2026-02-01T00:00:00.000Z",
                   "teams":{"nodes":[]}}
                ]}}}
                """)
        ])
        let adapter = Fixture.adapter(transport)

        let projects = try await adapter.linearProjects()

        #expect(projects.map(\.id.rawValue) == ["p1", "p2", "p3"])
        let engineering = BoardTeam(id: BoardObjectID(rawValue: "team-1"), key: "ENG", name: "Engineering")
        #expect(projects[0].teams == [engineering])
        #expect(!projects[0].isCompleted && !projects[0].isCanceled)
        #expect(projects[1].isCompleted && !projects[1].isCanceled)
        #expect(!projects[2].isCompleted && projects[2].isCanceled)
        #expect(try Fixture.variables(transport.requests[1])["first"] as? Int == 50)
        #expect(try Fixture.variables(transport.requests[2])["after"] as? String == "cursor-a")
    }
}

@Suite("Linear workspace identity")
struct LinearWorkspaceIdentityTests {
    @Test("workspace() decodes the organization's id, name and urlKey")
    func workspaceDecodes() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"data":{"organization":{"id":"org-1","name":"Acme","urlKey":"acme"}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        let workspace = try await adapter.workspace()

        #expect(workspace == BoardWorkspace(id: "org-1", name: "Acme", urlKey: "acme"))
        let query = try #require(try Fixture.body(transport.requests[1])["query"] as? String)
        #expect(query.contains("organization { id name urlKey }"))
    }

    @Test("A refused workspace read maps like the sibling reads")
    func workspaceRefusal() async throws {
        let adapter = Fixture.adapter(StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"errors":[{"message":"Forbidden"}]}"#, status: 403)
        ]))
        await #expect(throws: BoardError.self) {
            _ = try await adapter.workspace()
        }
    }
}
