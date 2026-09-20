import Domain
@testable import Engine
import Foundation
import Testing

// roadmap P9.4 added `BoardWrite.adoptIssue` and it must be purely additive: payloads the Outbox already
// persisted decode exactly as before, and the new case round-trips with its operation named as an update.

@Suite("BoardWrite coding")
struct BoardWriteCodingTests {
    private let issue = BoardObjectID(rawValue: "issue-1")

    @Test("The adoption write round-trips and is an issue update")
    func adoptIssueRoundTrips() throws {
        let write = BoardWrite.adoptIssue(
            issue: issue, parentKey: "feature:FEAT-1:0:create",
            undo: BoardIssueChange(parent: .set(BoardObjectID(rawValue: "old-feature")))
        )
        let data = try JSONEncoder().encode(write)
        #expect(try JSONDecoder().decode(BoardWrite.self, from: data) == write)
        #expect(write.operation == "issueUpdate")
        #expect(write.issueID == issue)
        #expect(!write.isCreate)
    }

    @Test("A previously persisted updateIssue payload still decodes")
    func persistedUpdateIssueDecodes() throws {
        let json = """
            {"updateIssue":{"change":{"addLabels":[],"parent":{"set":{"_0":"issue-1"}},"removeLabels":[]},\
            "issue":"issue-1","undo":{"addLabels":[],"parent":{"clear":{}},"removeLabels":[]}}}
            """
        let decoded = try JSONDecoder().decode(BoardWrite.self, from: Data(json.utf8))
        #expect(decoded == .updateIssue(
            issue: issue, change: BoardIssueChange(parent: .set(issue)), undo: BoardIssueChange(parent: .clear)
        ))
    }

    @Test("A previously persisted createIssue payload still decodes")
    func persistedCreateIssueDecodes() throws {
        let json = #"{"createIssue":{"_0":{"labels":[],"team":"issue-1","title":"T"},"parentKey":"k"}}"#
        let decoded = try JSONDecoder().decode(BoardWrite.self, from: Data(json.utf8))
        #expect(decoded == .createIssue(BoardIssueDraft(team: issue, title: "T"), parentKey: "k"))
    }
}
