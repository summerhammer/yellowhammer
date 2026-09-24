import Domain
import Foundation
import LinearAdapter
import Testing

/// `updateIssue`'s translation of `removeLabels`: Linear refuses the whole mutation if
/// `removedLabelIds` names a label the issue does not carry, so the adapter reads the issue's
/// current labels first and filters the requested removal down to what is actually present.
@Suite("Linear writing: label removal filtering")
struct LinearIssueLabelRemovalTests {
    @Test("updateIssue with removeLabels filters to labels currently on the issue")
    func filtersRemovalsToPresentLabels() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.removeLabels = [
            BoardObjectID(rawValue: "label-present"), BoardObjectID(rawValue: "label-absent")
        ]
        let labelsJson = #"{"data":{"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""labels":{"nodes":[{"id":"label-present"}]},"# // glossary:ignore GL001
            + #""project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let updateJson = #"{"data":{"issueUpdate":{"success":true,"# // glossary:ignore GL001
            + #""issue":{"id":"issue-1","description":null,"# // glossary:ignore GL001
            + #""updatedAt":"2026-09-16T00:00:00Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(labelsJson),
            Fixture.json(updateJson)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.updateIssue(issueID, change)

        #expect(transport.requests.count == 3)
        let variables = try Fixture.variables(transport.requests[2])
        guard let input = variables["input"] as? [String: Any] else {
            Issue.record("expected input in variables")
            return
        }
        let removedLabels = input["removedLabelIds"] as? [String]
        #expect(removedLabels == ["label-present"])
    }

    @Test("updateIssue omits removedLabelIds but still sends other fields when no requested removal is present")
    func omitsRemovedLabelIdsWhenNonePresent() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.title = "New Title"
        change.removeLabels = [BoardObjectID(rawValue: "label-absent")]
        let labelsJson = #"{"data":{"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""labels":{"nodes":[]},"# // glossary:ignore GL001
            + #""project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let updateJson = #"{"data":{"issueUpdate":{"success":true,"# // glossary:ignore GL001
            + #""issue":{"id":"issue-1","description":null,"# // glossary:ignore GL001
            + #""updatedAt":"2026-09-16T00:00:00Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(labelsJson),
            Fixture.json(updateJson)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.updateIssue(issueID, change)

        #expect(transport.requests.count == 3)
        let variables = try Fixture.variables(transport.requests[2])
        guard let input = variables["input"] as? [String: Any] else {
            Issue.record("expected input in variables")
            return
        }
        #expect(input["title"] as? String == "New Title")
        #expect(input["removedLabelIds"] == nil)
    }

    @Test("removals-only change with none present sends no issueUpdate, returns the description read")
    func removalsOnlyNonePresentSkipsUpdate() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.removeLabels = [BoardObjectID(rawValue: "label-absent")]
        let labelsJson = #"{"data":{"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""labels":{"nodes":[]},"# // glossary:ignore GL001
            + #""project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let descriptionJson = #"{"data":{"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""description":"Current description","updatedAt":"2023-11-14T22:13:20Z","# // glossary:ignore GL001
            + #""project":{"id":"\#(Fixture.linearProjectID)"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(labelsJson),
            Fixture.json(descriptionJson)
        ])
        let adapter = Fixture.adapter(transport)

        let snapshot = try await adapter.updateIssue(issueID, change)

        // Token, labels read, description read — no issueUpdate mutation.
        #expect(transport.requests.count == 3)
        #expect(snapshot.id == BoardObjectID(rawValue: "issue-1"))
        #expect(snapshot.description == "Current description")
    }

    @Test("updateIssue with empty removeLabels sends exactly one request, unchanged")
    func emptyRemoveLabelsUnchanged() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.title = "New Title"
        let json = #"{"data":{"issueUpdate":{"success":true,"# // glossary:ignore GL001
            + #""issue":{"id":"issue-1","description":null,"# // glossary:ignore GL001
            + #""updatedAt":"2026-09-16T00:00:00Z"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(json)
        ])
        let adapter = Fixture.adapter(transport)

        _ = try await adapter.updateIssue(issueID, change)

        // Token, then the single issueUpdate mutation — no labels read.
        #expect(transport.requests.count == 2)
    }

    @Test("the labels read is scoped: an issue outside the Linear project throws scopeNotFound")
    func labelsReadScoped() async throws {
        let issueID = BoardObjectID(rawValue: "issue-1")
        var change = BoardIssueChange()
        change.removeLabels = [BoardObjectID(rawValue: "label-present")]
        let labelsJson = #"{"data":{"issue":{"id":"issue-1","# // glossary:ignore GL001
            + #""labels":{"nodes":[{"id":"label-present"}]},"# // glossary:ignore GL001
            + #""project":{"id":"other-project"}}}}"#
        let transport = StubHTTPTransport([
            Fixture.token(),
            Fixture.json(labelsJson)
        ])
        let adapter = Fixture.adapter(transport)

        do {
            _ = try await adapter.updateIssue(issueID, change)
            Issue.record("expected scopeNotFound")
        } catch .scopeNotFound {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        // Token, labels read — no issueUpdate mutation.
        #expect(transport.requests.count == 2)
    }
}
