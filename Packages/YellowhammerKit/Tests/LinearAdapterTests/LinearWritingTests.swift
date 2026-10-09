import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear writing: creates")
struct LinearWritingTests {
    @Test("createIssue sends input with lowercased clientID, Linear project id, team id, parent, and labels")
    func createIssueVariables() async throws {
        let clientID = UUID()
        let teamID = BoardObjectID(rawValue: "team-123")
        let parentID = BoardObjectID(rawValue: "feature-456")
        let labelID = BoardObjectID(rawValue: "label-789")
        let draft = BoardIssueDraft(
            team: teamID, title: "Test Issue", description: "A test",
            parent: parentID, labels: [labelID]
        )
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-1"}}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.createIssue(draft, clientID: clientID)

        #expect(receipt == .created(BoardObjectID(rawValue: "issue-1")))
        let variables = try Fixture.variables(transport.requests[1])
        guard let input = variables["input"] as? [String: Any] else {
            Issue.record("expected input in variables")
            return
        }
        #expect(input["id"] as? String == clientID.uuidString.lowercased())
        #expect(input["projectId"] as? String == Fixture.linearProjectID)
        #expect(input["teamId"] as? String == "team-123")
        #expect(input["parentId"] as? String == "feature-456")
        let labelIds = input["labelIds"] as? [String]
        #expect(labelIds == ["label-789"])
    }

    @Test("createIssue omits nil optional fields")
    func createIssueOmitsNil() async throws {
        let clientID = UUID()
        let draft = BoardIssueDraft(team: BoardObjectID(rawValue: "team-1"), title: "Simple")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"data":{"issueCreate":{"success":true,"issue":{"id":"issue-1"}}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.createIssue(draft, clientID: clientID)

        let variables = try Fixture.variables(transport.requests[1])
        guard let input = variables["input"] as? [String: Any] else {
            Issue.record("expected input in variables")
            return
        }
        #expect(input["description"] == nil)
        #expect(input["parentId"] == nil)
        #expect(input["labelIds"] == nil)
        #expect(input["stateId"] == nil)
        #expect(input["assigneeId"] == nil)
    }

    @Test("createIssue on conflict-on-insert returns alreadyApplied with lowercased clientID")
    func createIssueConflict() async throws {
        let clientID = UUID()
        let draft = BoardIssueDraft(team: BoardObjectID(rawValue: "team-1"), title: "Test")
        let json = #"{"errors":[{"message":"conflict on insert of Issue","# // glossary:ignore GL001
            + #""extensions":{"code":"INVALID_INPUT"}}],"data":null}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json, status: 400)
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.createIssue(draft, clientID: clientID)

        #expect(receipt == .alreadyApplied(BoardObjectID(rawValue: clientID.uuidString.lowercased())))
    }

    @Test("createIssue on conflict with HTTP 200 returns alreadyApplied")
    func createIssueConflictHttp200() async throws {
        let clientID = UUID()
        let draft = BoardIssueDraft(team: BoardObjectID(rawValue: "team-1"), title: "Test")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"errors":[{"message":"conflict on insert of Issue"}],"data":null}"#, status: 200
            )
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.createIssue(draft, clientID: clientID)

        #expect(receipt == .alreadyApplied(BoardObjectID(rawValue: clientID.uuidString.lowercased())))
    }

    @Test("createComment on success returns created with comment id")
    func createCommentSuccess() async throws {
        let clientID = UUID()
        let issueID = BoardObjectID(rawValue: "issue-1")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(#"{"data":{"commentCreate":{"success":true,"comment":{"id":"comment-1"}}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.createComment(on: issueID, body: "Test", clientID: clientID)

        #expect(receipt == .created(BoardObjectID(rawValue: "comment-1")))
    }

    @Test("createComment on conflict-on-insert returns alreadyApplied")
    func createCommentConflict() async throws {
        let clientID = UUID()
        let issueID = BoardObjectID(rawValue: "issue-1")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"errors":[{"message":"conflict on insert of Comment"}],"data":null}"#, status: 400
            )
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.createComment(on: issueID, body: "Test", clientID: clientID)

        #expect(receipt == .alreadyApplied(BoardObjectID(rawValue: clientID.uuidString.lowercased())))
    }

    @Test("attachLink on success returns created with attachment id")
    func attachLinkSuccess() async throws {
        let clientID = UUID()
        let issueID = BoardObjectID(rawValue: "issue-1")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"attach-1"}}}}"#
            )
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.attachLink(
            to: issueID, url: "https://example.com", title: "Example", clientID: clientID
        )

        #expect(receipt == .created(BoardObjectID(rawValue: "attach-1")))
    }

    @Test("attachLink on conflict-on-insert returns alreadyApplied")
    func attachLinkConflict() async throws {
        let clientID = UUID()
        let issueID = BoardObjectID(rawValue: "issue-1")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"errors":[{"message":"conflict on insert of Attachment"}],"data":null}"#, status: 400
            )
        ])
        let adapter = Fixture.adapter(transport)

        let receipt = try await adapter.attachLink(
            to: issueID, url: "https://example.com", title: "Example", clientID: clientID
        )

        #expect(receipt == .alreadyApplied(BoardObjectID(rawValue: clientID.uuidString.lowercased())))
    }

    @Test("createIssue on rate limit (HTTP 429 with budget headers) throws rateLimited, not alreadyApplied")
    func createIssueRateLimited() async throws {
        let clientID = UUID()
        let draft = BoardIssueDraft(team: BoardObjectID(rawValue: "team-1"), title: "Test")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"errors":[{"message":"Rate limit exceeded","extensions":{"code":"RATELIMITED"}}]}"#,
                status: 429,
                headers: ["x-ratelimit-requests-limit": "5000", "x-ratelimit-requests-remaining": "0"]
            )
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.createIssue(draft, clientID: clientID)
            Issue.record("expected rateLimited")
        } catch .rateLimited {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("createIssue on HTTP 503 throws unreachable")
    func createIssue503() async throws {
        let clientID = UUID()
        let draft = BoardIssueDraft(team: BoardObjectID(rawValue: "team-1"), title: "Test")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json("Service Unavailable", status: 503)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.createIssue(draft, clientID: clientID)
            Issue.record("expected unreachable")
        } catch .unreachable(let message, _) {
            #expect(message.contains("503"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
