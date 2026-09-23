import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// The re-ready exception (roadmap P11.4; spec: bounds/bound-unanswered-nights): a Journal-Blocked Card
// under `unanswered` or `undecided`, read on the board as Todo with no pending write, is accepted as
// the Operator's re-ready — `reReadied`, not `restated` — with its counters untouched. Every other Block
// Reason keeps the existing restate behavior (DeltaReadReconciliationTests.swift,
// WaitingOnYouAnomalyTests.swift).

/// Inserts a fixture Card already Blocked under `reason`, with a non-zero `budget_epoch` so the test can
/// assert it survives the re-ready untouched.
@discardableResult
private func insertBlockedCard(
    _ journal: JournalStore, issueID: String, reason: BlockReason, budgetEpoch: Int = 2
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(deltaEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(deltaEpoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "backend", "impl", 1, CardState.blocked.rawValue, reason.rawValue, budgetEpoch,
                JournalStore.timestamp(deltaEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Suite("The re-ready exception (P11.4)")
struct DeltaReadReReadyTests {
    @Test("A Card Blocked `unanswered`, read as Todo, is re-readied: Journal Todo, budget_epoch untouched")
    func unansweredBlockIsReReadied() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .unanswered)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.reReadied.map(\.issueID) == ["card-1"])
        #expect(report.restated.isEmpty, "a re-ready is not a restate")

        let card = try journal.card(id: cardID)
        #expect(card.state == .todo)
        #expect(card.blockReason == nil)
        #expect(card.budgetEpoch == 2, "re-ready never resets budget_epoch")
    }

    @Test("A Card Blocked `undecided`, read as Todo, is re-readied the same way")
    func undecidedBlockIsReReadied() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .undecided)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.reReadied.map(\.issueID) == ["card-1"])
        #expect(try journal.card(id: cardID).state == .todo)
    }

    @Test("A Card Blocked `hard failure`, read as Todo, is still restated — the exception is narrow")
    func hardFailureBlockIsStillRestated() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .hardFailure)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.reReadied.isEmpty)
        #expect(report.restated.map(\.card.issueID) == ["card-1"])
        #expect(try journal.card(id: cardID).state == .blocked, "restated, not re-readied: the Journal stays Blocked")
    }
}
