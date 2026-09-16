import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/maintain-the-managed-block: a description is written only by a fenced rewrite after
// a pre-flight read that is never a cache; broken delimiters abort the write, are recorded, and are
// reported to the Operator on the issue.

@Suite("Outbox: Managed Block rewrites")
struct OutboxManagedBlockTests {
    // MARK: - Managed Block

    @Test("A rewrite replaces only the text between the delimiters and records the prose hash")
    func fencedRewritePreservesProse() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: fencedDescription)
        let outbox = try outbox(journal, board: board)

        let delivery = try await outbox.post(
            OutboxWrite(
                key: "block:issue-1", write: .rewriteManagedBlock(issue: issue, rendered: "new block\nline two")
            )
        )

        #expect(delivery.outcome == .applied(nil))
        let written = try #require(await board.issue(issue)?.description)
        #expect(written == """
            The Operator wrote this above.

            <!-- yh:managed:start -->
            new block
            line two
            <!-- yh:managed:end -->

            And this below — with a trailing note.
            """)
        let preserved = "The Operator wrote this above.\n\n<!-- yh:managed:start -->"
            + "<!-- yh:managed:end -->\n\nAnd this below — with a trailing note."
        let events = try journal.events(ofType: .managedBlockWritten)
        #expect(events.count == 1)
        #expect(events.first?.event == .managedBlockWritten(
            issueID: "issue-1",
            preservedProseHash: ManagedBlockFence.sha256(preserved),
            renderedHash: ManagedBlockFence.sha256("new block\nline two")
        ))
        let renderedHash = ManagedBlockFence.sha256("new block\nline two")
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == renderedHash)
    }

    @Test("The pre-flight read is just in time: an Operator edit after acceptance is what gets preserved")
    func preflightReadIsJustInTime() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: fencedDescription)
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(key: "block:issue-1", write: .rewriteManagedBlock(issue: issue, rendered: "new"))
        _ = try outbox.accept(write)

        let edited = "Edited at 3am.\n<!-- yh:managed:start -->\nold\n<!-- yh:managed:end -->"
        await board.edit(issue, description: edited)
        _ = try await outbox.deliverPending()

        let expected = "Edited at 3am.\n<!-- yh:managed:start -->\nnew\n<!-- yh:managed:end -->"
        #expect(await board.issue(issue)?.description == expected)
        #expect(await board.descriptionReads == 1)
    }

    @Test(
        "Broken delimiters abort the write, record ManagedBlockDelimiterBroken and post one diagnostic comment",
        arguments: [
            nil,
            "no delimiters at all",
            "<!-- yh:managed:start -->\nonly a start",
            "only an end\n<!-- yh:managed:end -->",
            "<!-- yh:managed:end -->\nbackwards\n<!-- yh:managed:start -->",
            "<!-- yh:managed:start -->\ntwice\n<!-- yh:managed:start -->\n<!-- yh:managed:end -->"
        ] as [String?]
    )
    func brokenDelimitersAbortSafely(_ description: String?) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: description)
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(key: "block:issue-1", write: .rewriteManagedBlock(issue: issue, rendered: "new"))

        let delivery = try await outbox.post(write)

        guard case .aborted = delivery.outcome else {
            Issue.record("expected aborted, got \(delivery.outcome)")
            return
        }
        #expect(await board.updateCalls == 0)
        #expect(await board.issue(issue)?.description == description)
        let broken = try journal.events(ofType: .managedBlockDelimiterBroken).map(\.event)
        #expect(broken == [.managedBlockDelimiterBroken(issueID: "issue-1")])
        let comments = await board.comments
        #expect(comments.count == 1)
        #expect(comments.first?.body.contains("<!-- yh:managed:start -->") == true)
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == nil)

        // The same write again does not post a second diagnostic.
        _ = try await outbox.post(write)
        #expect(await board.comments.count == 1)
    }
}
