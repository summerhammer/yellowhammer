import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// roadmap P17.5, Linear Board Connection Ruling: a write refused as BoardError.notAuthenticated is not
// a permanent failure like .refused/.scopeNotFound/.forbidden — it stays pending so the Act above halts
// and the write replays once re-authorized. Split out from OutboxTests.swift (SwiftLint's
// type_body_length).

@Suite("Outbox authorization refusal (P17.5)")
struct OutboxAuthorizationTests {
    @Test("An authorization refusal (notAuthenticated) throws, stays pending, and replays once re-authorized")
    func authorizationRefusalStaysPendingAndReplays() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        await board.refuseNext(.notAuthenticated("sign-in expired"))
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(
            key: "state:issue-1:done",
            write: .updateIssue(
                issue: issue, change: BoardIssueChange(workflowState: BoardObjectID(rawValue: "s")), undo: nil
            )
        )

        await #expect(throws: BoardError.self) { try await outbox.post(write) }

        // Not failed, not attempted-count-exhausted: it stays pending, unchanged.
        let pending = try journal.pendingOutboxEntries()
        #expect(pending.count == 1)
        #expect(pending.first?.attemptCount == 0)

        // Once the board accepts (re-authorized), the same entry, under its unchanged client id, applies.
        let delivery = try await outbox.deliver(pending[0])
        guard case .applied = delivery.outcome else {
            Issue.record("expected applied on replay, got \(delivery.outcome)")
            return
        }
        #expect(try journal.pendingOutboxEntries().isEmpty)
    }

    @Test("deliverPending propagates an authorization refusal instead of swallowing it, entry stays pending")
    func deliverPendingPropagatesAuthorizationRefusal() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let outbox = try outbox(journal, board: board)
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))
        await board.refuseNext(.notAuthenticated("sign-in expired"))

        // This is the safety net every Act's `writeBack` relies on (unguarded `try await
        // outbox.deliverPending()`): even a write a caller queued through a swallowed `try?
        // outbox.post(...)` still stays pending, and this unconditional end-of-Act flush is what
        // surfaces the refusal so the Act halts, rather than ending "successfully" past it.
        await #expect(throws: BoardError.self) { try await outbox.deliverPending() }
        #expect(try journal.pendingOutboxEntries().count == 1)
    }
}
