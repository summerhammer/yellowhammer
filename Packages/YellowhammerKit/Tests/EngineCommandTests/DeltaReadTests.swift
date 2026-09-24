import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/read-board-changes-by-delta: each Act reads what changed since the last read in one
// request; Yellowhammer's own comments are filtered by identity; Cancelled is read and never written;
// deleted or re-stated Cards are reconciled against the Journal, which stays authoritative; a Card
// moved to another repository is reported rather than dispatched; a rate-budget refusal degrades the
// read and is recorded as workspace-wide. These run against an in-memory Linear stand-in.

@Suite("Delta Read")
struct DeltaReadTests {
    // MARK: - One request, sync point

    @Test("A human comment and a state change are picked up by one request, and the sync point advances")
    func oneRequestPicksUpCommentAndState() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", state: .waitingOnYou)
        let board = FakeReadingBoard([
            page(
                objects: [object("card-1", state: stateBlocked, updatedAt: 30)],
                comments: [comment("c-1", on: "card-1", author: humanAuthor, parent: "q-1", createdAt: 45)]
            )
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.requests == 1)
        #expect(await board.calls.map(\.since) == [nil])
        #expect(await board.calls.map(\.pageSize) == [50])
        #expect(report.humanComments.map(\.comment.id) == [BoardObjectID(rawValue: "c-1")])
        #expect(report.humanComments[0].card?.issueID == "card-1")
        #expect(report.humanComments[0].isThreadedReply)
        #expect(report.restated.map(\.boardState.name) == ["Blocked"])
        #expect(report.operatorEdits.map(\.card.issueID) == ["card-1"])
        #expect(report.syncPoint == deltaEpoch.addingTimeInterval(45))
        #expect(try journal.boardSyncPoint()?.lastSync == deltaEpoch.addingTimeInterval(45))
        // The Journal stays authoritative for the state.
        #expect(try journal.card(issueID: "card-1")?.state == .waitingOnYou)
        #expect(try journal.events(ofType: .cardRestated).count == 1)
        #expect(try journal.events(ofType: .deltaReadCompleted).count == 1)
    }

    @Test("The next Act reads since the recorded sync point, and an empty read leaves it unchanged")
    func nextReadStartsFromSyncPoint() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([
            page(objects: [object("f-1", state: stateTodo, updatedAt: 7.5)]),
            page()
        ])
        let (read, _) = try deltaRead(journal, board: board)

        _ = try await read.perform()
        _ = try await read.perform()

        let calls = await board.calls
        #expect(calls.map(\.since) == [nil, deltaEpoch.addingTimeInterval(7.5)])
        #expect(try journal.boardSyncPoint()?.lastSync == deltaEpoch.addingTimeInterval(7.5))
    }

    @Test("A page that overflows is followed by its cursor, per root")
    func pagesFollowCursors() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([
            page(
                objects: [object("f-1", state: stateTodo, updatedAt: 1)],
                comments: [comment("c-1", on: "f-1", author: humanAuthor, createdAt: 2)],
                nextObjectCursor: BoardCursor(rawValue: "o-2")
            ),
            page(
                objects: [object("f-2", state: stateTodo, updatedAt: 3)],
                nextCommentCursor: BoardCursor(rawValue: "c-2")
            ),
            page(comments: [comment("c-2", on: "f-2", author: humanAuthor, createdAt: 4)])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.requests == 3)
        let calls = await board.calls
        #expect(calls.map(\.objectsAfter) == [nil, BoardCursor(rawValue: "o-2"), nil])
        #expect(calls.map(\.commentsAfter) == [nil, nil, BoardCursor(rawValue: "c-2")])
        #expect(report.unknownObjects.count == 2)
        #expect(report.humanComments.count == 2)
        #expect(report.syncPoint == deltaEpoch.addingTimeInterval(4))
    }

    // MARK: - Self-comment filtering

    @Test("Yellowhammer's own comments are filtered by isMe and by identity id, and nothing else is")
    func ownCommentsFiltered() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let own = BoardCommentAuthor(id: FakeReadingBoard.identity.id, name: "Yellowhammer", isYellowhammer: false)
        let flagged = BoardCommentAuthor(
            id: BoardObjectID(rawValue: "bot-7"), name: "Yellowhammer", isYellowhammer: true
        )
        let nameless = BoardCommentAuthor(id: nil, name: "unknown", isYellowhammer: false)
        let board = FakeReadingBoard([
            page(comments: [
                comment("c-own", on: "x", author: own),
                comment("c-flagged", on: "x", author: flagged),
                comment("c-humanAuthor", on: "x", author: humanAuthor),
                comment("c-nameless", on: "x", author: nameless)
            ])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.ownComments == 2)
        #expect(report.humanComments.map(\.comment.id.rawValue) == ["c-humanAuthor", "c-nameless"])
        #expect(report.humanComments.allSatisfy { $0.card == nil })
    }

    // MARK: - Cancelled

    @Test("Cancelled is read and recorded at the Act boundary, and reopening restores the state held")
    func cancelledRoundTrip() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .blocked)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateCancelled, updatedAt: 1)]),
            page(objects: [object("card-1", state: stateCancelled, updatedAt: 2)]),
            page(objects: [object("card-1", state: stateTodo, updatedAt: 3)])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let first) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(first.cancelled.map(\.id) == [cardID])
        #expect(first.restated.isEmpty)
        #expect(try journal.card(id: cardID).state == .cancelled)
        #expect(try journal.card(id: cardID).cancelledFromState == .blocked)

        guard case .read(let again) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(again.cancelled.isEmpty, "a Card already cancelled is not cancelled twice")

        guard case .read(let reopened) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(reopened.reopened.map(\.id) == [cardID])
        #expect(reopened.restated.isEmpty, "the restored Journal state wins over the board's reopen state")
        #expect(try journal.card(id: cardID).state == .blocked)
        #expect(try journal.card(id: cardID).cancelledFromState == nil)
        #expect(try journal.events(ofType: .cardCancelled).count == 1)
        #expect(try journal.events(ofType: .cardReopened).count == 1)
    }

    @Test("A board state named 'Canceled' of category .cancelled marks the Card Cancelled; Todo reopens it")
    func cancelledByCategoryRoundTrip() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .blocked)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateCanceledByCategory, updatedAt: 1)]),
            page(objects: [object("card-1", state: stateTodo, updatedAt: 2)])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let first) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(first.cancelled.map(\.id) == [cardID])
        #expect(try journal.card(id: cardID).state == .cancelled)

        guard case .read(let reopened) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(reopened.reopened.map(\.id) == [cardID])
        #expect(try journal.card(id: cardID).state == .blocked)
    }

    // MARK: - Re-stated and removed Cards

    @Test("A state the Journal did not write is reported, unless a write to that issue is still pending")
    func restatedUnlessProjectionPending() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", state: .blocked)
        try insertCard(journal, issueID: "card-2", state: .blocked)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateTodo), object("card-2", state: stateTodo)])
        ])
        let (read, runID) = try deltaRead(journal, board: board)
        // The Outbox has accepted a state write for card-2 that has not reached Linear yet.
        let pending = BoardWrite.updateIssue(
            issue: BoardObjectID(rawValue: "card-2"),
            change: BoardIssueChange(workflowState: stateBlocked.id), undo: nil
        )
        let payload = String(data: try JSONEncoder().encode(pending), encoding: .utf8) ?? ""
        _ = try journal.acceptOutbox(
            [OutboxDraft(clientID: UUID(), issueID: "card-2", operation: pending.operation, payload: payload)],
            runID: runID
        )

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.restated.map(\.card.issueID) == ["card-1"])
        #expect(report.cardChanges.map(\.stateDiffers) == [true, false])
        #expect(try journal.card(issueID: "card-1")?.state == .blocked)
    }

    @Test("A Card the Operator deleted is reported as removed; a Done Card Linear archived is not")
    func removedCards() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-live", state: .todo)
        try insertCard(journal, issueID: "card-done", state: .done)
        try insertCard(journal, issueID: "card-trashed", state: .done)
        let done = BoardWorkflowState(id: BoardObjectID(rawValue: "s-done"), name: "Done")
        let board = FakeReadingBoard([
            page(objects: [
                object("card-live", state: stateTodo, archivedAt: 5),
                object("card-done", state: done, archivedAt: 5),
                object("card-trashed", state: done, archivedAt: 5, isTrashed: true)
            ])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        let removed = report.removed.map { "\($0.card.issueID):\($0.how.rawValue)" }
        #expect(removed == ["card-live:archived", "card-trashed:trashed"])
        #expect(try journal.events(ofType: .cardRemovedFromBoard).count == 2)
        // Reported, never deleted: the Journal rows are intact.
        #expect(try journal.cards().count == 3)
    }
}
