import Domain
import Foundation
import LinearAdapter
import Testing

@Suite("Linear writing: updates")
struct LinearIssueUpdateTests {
    @Test("updateIssue sends only the given fields in input")
    func updateIssueOnlyGivenFields() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.title = "New Title"
        let json = #"{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""description":null,"updatedAt":"2026-09-16T00:00:00Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.updateIssue(issueID, change)

        let variables = try Fixture.variables(transport.requests[1])
        guard let input = variables["input"] as? [String: Any] else {
            Issue.record("expected input in variables")
            return
        }
        #expect(input["title"] as? String == "New Title")
        #expect(input["description"] == nil)
        #expect(input["stateId"] == nil)
        #expect(input["addedLabelIds"] == nil)
        #expect(input["removedLabelIds"] == nil)
        #expect(input["assigneeId"] == nil)
        #expect(input["parentId"] == nil)
    }

    @Test("updateIssue encodes clear parent as JSON null in the request body")
    func updateIssueClearParentAsNull() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.parent = .clear
        let json = #"{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""description":null,"updatedAt":"2026-09-16T00:00:00Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.updateIssue(issueID, change)

        let requestBody = try #require(transport.requests[1].httpBody)
        // Verify the raw body contains "parentId":null
        let bodyString = String(data: requestBody, encoding: .utf8) ?? ""
        #expect(bodyString.contains(#""parentId":null"#))
    }

    @Test("updateIssue with addedLabelIds and removedLabelIds sends both")
    func updateIssueAddAndRemoveLabels() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.addLabels = [BoardObjectID(rawValue: "label-add")]
        change.removeLabels = [BoardObjectID(rawValue: "label-remove")]
        let json = #"{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""description":null,"updatedAt":"2026-09-16T00:00:00Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.updateIssue(issueID, change)

        let variables = try Fixture.variables(transport.requests[1])
        guard let input = variables["input"] as? [String: Any] else {
            Issue.record("expected input in variables")
            return
        }
        let addedLabels = input["addedLabelIds"] as? [String]
        let removedLabels = input["removedLabelIds"] as? [String]
        #expect(addedLabels == ["label-add"])
        #expect(removedLabels == ["label-remove"])
    }

    @Test("updateIssue returns description and updatedAt from the response")
    func updateIssueReturnsSnapshot() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.title = "New"
        let json = #"{"data":{"issueUpdate":{"success":true,"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""description":"Updated description","updatedAt":"2023-11-14T22:13:20Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        let snapshot = try await adapter.updateIssue(issueID, change)

        #expect(snapshot.id == BoardObjectID(rawValue: "issue-1"))
        #expect(snapshot.description == "Updated description")
        #expect(snapshot.updatedAt.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("updateIssue on empty change throws refused without a request")
    func updateIssueEmptyChange() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let change = BoardIssueChange()
        let transport = StubHTTPTransport([Fixture.token()])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.updateIssue(issueID, change)
            Issue.record("expected refused")
        } catch .refused {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Not even the token was requested: nothing was going to be sent.
        #expect(transport.requests.isEmpty)
    }

    @Test("issueDescription returns snapshot with id, description and updatedAt")
    func issueDescriptionReturnsSnapshot() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let json = #"{"data":{"issue":{"id":"issue-1","description":"Test description","# // glossary:ignore GL001
            + #""updatedAt":"2023-11-14T22:13:20Z","project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        let snapshot = try await adapter.issueDescription(issueID)

        #expect(snapshot.id == BoardObjectID(rawValue: "issue-1"))
        #expect(snapshot.description == "Test description")
        #expect(snapshot.updatedAt.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("issueDescription when issue is null throws scopeNotFound")
    func issueDescriptionNotFound() async throws {
        let issueID = BoardObjectID(rawValue: "issue-missing")
        let json = #"{"data":{"issue":null,"project":{"id":"\#(Fixture.linearProjectID)"}},"# // glossary:ignore GL001
            + #""errors":[{"message":"Entity not found"}]}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.issueDescription(issueID)
            Issue.record("expected scopeNotFound")
        } catch .scopeNotFound {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("issueDescription when Linear project is null throws scopeNotFound")
    func issueDescriptionProjectNull() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let json = #"{"data":{"issue":{"id":"issue-1","description":"Test","# // glossary:ignore GL001
            + #""updatedAt":"2023-11-14T22:13:20Z","project":null}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.issueDescription(issueID)
            Issue.record("expected scopeNotFound")
        } catch .scopeNotFound {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("issueDescription when Linear project id mismatch throws scopeNotFound")
    func issueDescriptionWrongProject() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let json = #"{"data":{"issue":{"id":"issue-1","description":"Test","# // glossary:ignore GL001
            + #""updatedAt":"2023-11-14T22:13:20Z","project":{"id":"other-project"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.issueDescription(issueID)
            Issue.record("expected scopeNotFound")
        } catch .scopeNotFound {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("issueDescription scrubs token from error message")
    func issueDescriptionScrubsToken() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(
                #"{"data":{"issue":null},"errors":[{"message":"Entity not found: \#(Fixture.accessToken)"}]}"#
            )
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.issueDescription(issueID)
            Issue.record("expected error")
        } catch .scopeNotFound(let message) {
            #expect(!message.contains(Fixture.accessToken))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("archiveIssue makes two requests: scope check then archive")
    func archiveIssueTwoRequests() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let json = #"{"data":{"issue":{"id":"issue-1","description":null,"# // glossary:ignore GL001
            + #""updatedAt":"2023-11-14T22:13:20Z","project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json),
            Fixture.json(#"{"data":{"issueArchive":{"success":true}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        try await adapter.archiveIssue(issueID)

        // Token, description check, archive
        #expect(transport.requests.count == 3)
    }

    @Test("archiveIssue when scope check fails does not make archive request")
    func archiveIssueWrongProjectNoArchive() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let json = #"{"data":{"issue":{"id":"issue-1","description":null,"# // glossary:ignore GL001
            + #""updatedAt":"2023-11-14T22:13:20Z","project":{"id":"other-project"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            try await adapter.archiveIssue(issueID)
            Issue.record("expected scopeNotFound")
        } catch .scopeNotFound {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Only token and description check, no archive request
        #expect(transport.requests.count == 2)
    }

    @Test("archiveIssue when success is false throws refused")
    func archiveIssueRefused() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        let json = #"{"data":{"issue":{"id":"issue-1","description":null,"# // glossary:ignore GL001
            + #""updatedAt":"2023-11-14T22:13:20Z","project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json),
            Fixture.json(#"{"data":{"issueArchive":{"success":false}}}"#)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            try await adapter.archiveIssue(issueID)
            Issue.record("expected refused")
        } catch .refused {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
