import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear delta read decoding")
struct LinearDeltaReadDecodingTests {
    @Test("An issue with archivedAt, trashed, and assignee maps correctly")
    func issueDecodingWithArchiveAndAssignee() async throws {
        let issueJSON = """
            {"id":"archived-issue","identifier":"ENG-999","title":"Deleted",
             "description":null,"url":"https://linear.app/acme/issue/ENG-999",
             "createdAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-15T22:00:00Z",
             "archivedAt":"2026-09-16T10:00:00Z","trashed":true,
             "state":{"id":"state-1","name":"Cancelled"},
             "labels":{"nodes":[]},"parent":null,"assignee":{"id":"user-123"}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(issueNodes: issueJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.updatedObjects.count == 1)
        let issue = try #require(delta.updatedObjects.first)
        #expect(issue.id == BoardObjectID(rawValue: "archived-issue"))
        #expect(issue.isTrashed == true)
        #expect(issue.archivedAt == Date(timeIntervalSince1970: 1_789_552_800))
        #expect(issue.assignee == BoardObjectID(rawValue: "user-123"))
    }

    @Test("An issue without archivedAt, trashed, and assignee maps to nil/false")
    func issueDecodingWithoutOptionalFields() async throws {
        let issueJSON = """
            {"id":"live-issue","identifier":"ENG-123","title":"Open",
             "description":"Body","url":"https://linear.app/acme/issue/ENG-123",
             "createdAt":"2026-09-01T10:00:00Z","updatedAt":"2026-09-15T22:00:00Z",
             "state":{"id":"state-1","name":"In Progress"},
             "labels":{"nodes":[{"name":"yh:card"}]},"parent":null}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(issueNodes: issueJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.updatedObjects.count == 1)
        let issue = try #require(delta.updatedObjects.first)
        #expect(issue.isTrashed == false)
        #expect(issue.archivedAt == nil)
        #expect(issue.assignee == nil)
    }

    @Test("A human comment with isMe:false maps to isYellowhammer == false")
    func humanCommentNotYellowhammer() async throws {
        let commentJSON = """
            {"id":"c1","createdAt":"2026-09-15T12:00:00Z","body":"What's up?",
             "parent":null,"user":{"id":"u456","name":"Alice","isMe":false},
             "botActor":null,"issue":{"id":"i1","identifier":"ENG-123","state":{"id":"s1","name":"In Progress"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.id == BoardObjectID(rawValue: "u456"))
        #expect(comment.author.name == "Alice")
        #expect(comment.author.isYellowhammer == false)
    }

    @Test("A human comment with isMe:true maps to isYellowhammer == true")
    func humanCommentIsYellowhammer() async throws {
        let commentJSON = """
            {"id":"c2","createdAt":"2026-09-15T12:00:00Z","body":"Here's my answer",
             "parent":null,"user":{"id":"app-user-id","name":"Yellowhammer","isMe":true},
             "botActor":null,"issue":{"id":"i1","identifier":"ENG-123","state":{"id":"s1","name":"Waiting on You"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.isYellowhammer == true)
    }

    @Test("A bot comment with id matching viewer id maps to isYellowhammer == true")
    func botCommentMatchingViewerID() async throws {
        let commentJSON = """
            {"id":"comment-3","createdAt":"2026-09-15T12:00:00Z","body":"Integration response",
             "parent":null,"user":null,"botActor":{"id":"app-user-id","name":"GitHub Bot"},
             "issue":{"id":"issue-1","identifier":"ENG-123","state":{"id":"state-1","name":"In Review"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.id == BoardObjectID(rawValue: "app-user-id"))
        #expect(comment.author.name == "GitHub Bot")
        #expect(comment.author.isYellowhammer == true)
    }

    @Test("A bot comment with id not matching viewer id maps to isYellowhammer == false")
    func botCommentNotMatchingViewerID() async throws {
        let commentJSON = """
            {"id":"comment-4","createdAt":"2026-09-15T12:00:00Z","body":"Other bot",
             "parent":null,"user":null,"botActor":{"id":"other-bot-id","name":"Slack Bot"},
             "issue":{"id":"issue-1","identifier":"ENG-123","state":{"id":"state-1","name":"Open"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.isYellowhammer == false)
    }

    @Test("A bot comment with nil id maps to unknown")
    func botCommentNilID() async throws {
        let commentJSON = """
            {"id":"comment-5","createdAt":"2026-09-15T12:00:00Z","body":"Mystery bot",
             "parent":null,"user":null,"botActor":{"id":null,"name":"Unknown Bot"},
             "issue":{"id":"issue-1","identifier":"ENG-123","state":{"id":"state-1","name":"Open"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.name == "Unknown Bot")
    }

    @Test("A bot comment with nil name defaults to integration")
    func botCommentNilName() async throws {
        let commentJSON = """
            {"id":"comment-6","createdAt":"2026-09-15T12:00:00Z","body":"Unnamed bot",
             "parent":null,"user":null,"botActor":{"id":"bot-123","name":null},
             "issue":{"id":"issue-1","identifier":"ENG-123","state":{"id":"state-1","name":"Open"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.name == "integration")
    }

    @Test("A comment with no user and no botActor maps to unknown")
    func commentNoAuthor() async throws {
        let commentJSON = """
            {"id":"comment-7","createdAt":"2026-09-15T12:00:00Z","body":"Orphan comment",
             "parent":null,"user":null,"botActor":null,
             "issue":{"id":"issue-1","identifier":"ENG-123","state":{"id":"state-1","name":"Open"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.author.id == nil)
        #expect(comment.author.name == "unknown")
        #expect(comment.author.isYellowhammer == false)
    }

    @Test("A threaded reply carries parent")
    func threadedReply() async throws {
        let commentJSON = """
            {"id":"r1","createdAt":"2026-09-15T12:30:00Z","body":"Reply to question",
             "parent":{"id":"c1"},"user":{"id":"u456","name":"Alice","isMe":false},
             "botActor":null,"issue":{"id":"i1","identifier":"ENG-123","state":{"id":"s1","name":"In Progress"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.parent == BoardObjectID(rawValue: "c1"))
    }

    @Test("Comment has issueKey and issueWorkflowState from nested issue")
    func commentIssueMetadata() async throws {
        let commentJSON = """
            {"id":"comment-8","createdAt":"2026-09-15T12:00:00Z","body":"Check this",
             "parent":null,"user":{"id":"user-456","name":"Alice","isMe":false},
             "botActor":null,"issue":{"id":"issue-42","identifier":"BKN-567","state":{"id":"state-2","name":"Blocked"}}}
            """
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.delta(commentNodes: commentJSON)
        ])
        let adapter = Fixture.adapter(transport)
        let delta = try await adapter.deltaRead(
            since: nil, objectsAfter: nil, commentsAfter: nil, pageSize: 50
        )

        #expect(delta.newComments.count == 1)
        let comment = try #require(delta.newComments.first)
        #expect(comment.issue == BoardObjectID(rawValue: "issue-42"))
        #expect(comment.issueKey == "BKN-567")
        #expect(comment.issueWorkflowState.name == "Blocked")
    }
}
