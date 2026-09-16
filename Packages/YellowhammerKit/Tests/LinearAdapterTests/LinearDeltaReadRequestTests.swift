import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear delta read requests")
struct LinearDeltaReadRequestTests {
    @Test("One request is sent for a delta read")
    func singleRequest() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        _ = try await Fixture.adapter(transport).deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(transport.requests.count == 2) // token + delta read
        let requestBody = try Fixture.body(transport.requests[1])
        #expect(try #require(requestBody["query"] as? String).contains("updatedIssues:"))
        #expect(try #require(requestBody["query"] as? String).contains("newComments:"))
        #expect(try #require(requestBody["query"] as? String).contains("includeArchived: true"))
    }

    @Test("Both filters carry the Linear project scope unconditionally")
    func projectScopeInBothFilters() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        _ = try await Fixture.adapter(transport).deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        let variables = try Fixture.variables(transport.requests[1])
        let issueFilter = try #require(variables["issueFilter"] as? [String: Any])
        let commentFilter = try #require(variables["commentFilter"] as? [String: Any])

        // Issue filter should have project scope
        let issueProject = try #require(issueFilter[Fixture.scopeKey] as? [String: Any])
        #expect((issueProject["id"] as? [String: Any])?["eq"] as? String == Fixture.linearProjectID)

        // Comment filter should have issue.project scope
        let commentIssue = try #require(commentFilter["issue"] as? [String: Any])
        let commentProject = try #require(commentIssue[Fixture.scopeKey] as? [String: Any])
        #expect((commentProject["id"] as? [String: Any])?["eq"] as? String == Fixture.linearProjectID)
    }

    @Test("With since given, both filters carry the gt clause with fractional timestamp")
    func sinceLessThanClause() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        let since = Date(timeIntervalSince1970: 1_789_000_000.5)
        _ = try await Fixture.adapter(transport).deltaRead(
            since: since, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        let variables = try Fixture.variables(transport.requests[1])
        let issueFilter = try #require(variables["issueFilter"] as? [String: Any])
        let commentFilter = try #require(variables["commentFilter"] as? [String: Any])

        let issueUpdatedAt = try #require(issueFilter["updatedAt"] as? [String: Any])
        let issueGt = try #require(issueUpdatedAt["gt"] as? String)
        #expect(issueGt == "2026-09-10T00:26:40.500Z")

        let commentCreatedAt = try #require(commentFilter["createdAt"] as? [String: Any])
        let commentGt = try #require(commentCreatedAt["gt"] as? String)
        #expect(commentGt == "2026-09-10T00:26:40.500Z")
    }

    @Test("With since nil, neither filter carries a time clause")
    func sinceNilNoTimeClause() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        let adapter = Fixture.adapter(transport)
        _ = try await adapter.deltaRead(since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50)

        let variables = try Fixture.variables(transport.requests[1])
        let issueFilter = try #require(variables["issueFilter"] as? [String: Any])
        let commentFilter = try #require(variables["commentFilter"] as? [String: Any])

        #expect(!issueFilter.keys.contains("updatedAt"))
        #expect(!commentFilter.keys.contains("createdAt"))
    }

    @Test("first equals the page size and issuesAfter/commentsAfter are absent when nil")
    func paginationVariablesAbsentWhenNil() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        let adapter = Fixture.adapter(transport)
        _ = try await adapter.deltaRead(since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50)

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["first"] as? Int == 50)
        #expect(variables["issuesAfter"] == nil)
        #expect(variables["commentsAfter"] == nil)
    }

    @Test("issuesAfter and commentsAfter are present when given")
    func paginationVariablesPresent() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        let issuesCursor = BoardCursor(rawValue: "issue-cursor-123")
        let commentsCursor = BoardCursor(rawValue: "comment-cursor-456")
        _ = try await Fixture.adapter(transport).deltaRead(
            since: nil,
            objectsAfter: issuesCursor,
            commentsAfter: commentsCursor,
            pageSize: 50
        )

        let variables = try Fixture.variables(transport.requests[1])
        #expect(variables["issuesAfter"] as? String == "issue-cursor-123")
        #expect(variables["commentsAfter"] as? String == "comment-cursor-456")
    }

    @Test("hasNextPage on issues independently drives nextObjectCursor")
    func issuesCursorDrivenByHasNextPage() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(issueHasNextPage: true, issueEndCursor: "issue-next", commentHasNextPage: false)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.nextObjectCursor == BoardCursor(rawValue: "issue-next"))
        #expect(delta.nextCommentCursor == nil)
    }

    @Test("hasNextPage on comments independently drives nextCommentCursor")
    func commentsCursorDrivenByHasNextPage() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(
                issueHasNextPage: false, commentHasNextPage: true,
                commentEndCursor: "comment-next"
            )
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.nextObjectCursor == nil)
        #expect(delta.nextCommentCursor == BoardCursor(rawValue: "comment-next"))
    }

    @Test("A 429 reply surfaces as rateLimited")
    func rateLimitedError() async throws {
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"errors":[{"message":"Too many"}]}"#, status: 429,
                headers: [
                    "Retry-After": "60", "x-ratelimit-requests-remaining": "0",
                    "x-ratelimit-requests-limit": "5000"
                ]
            )
        ])
        let adapter = Fixture.adapter(transport)
        await #expect(throws: BoardError.rateLimited(
            retryAfter: .seconds(60), budget: BoardBudget(requestsLimit: 5000, requestsRemaining: 0)
        )) {
            _ = try await adapter.deltaRead(since: nil)
        }
    }

    @Test("Delta read identity matches viewer from response")
    func identityFromViewer() async throws {
        let transport = StubHTTPTransport([Fixture.token(), Fixture.delta()])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.identity.id == BoardObjectID(rawValue: "app-user-id"))
        #expect(delta.identity.name == "Yellowhammer")
    }
}
