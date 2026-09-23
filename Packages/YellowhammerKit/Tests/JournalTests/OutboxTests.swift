import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// Helper to insert a fixture feature → cycle → card chain and return the card id.
private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String,
    authoredOrder: Int = 1
) throws -> Int64 {
    try journal.write { db in
        // Insert feature
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID

        // Insert cycle
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID: Int64 = db.lastInsertedRowID

        // Insert card
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch,
            created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", authoredOrder, CardState.todo.rawValue, 0,
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Test("A fresh Journal has v18-predecessor-gate applied last")
func v5MigrationApplied() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let migrations = try journal.appliedMigrations()
    #expect(migrations.contains("v4-outbox-delivery"))
    #expect(migrations.last == "v25-card-unanswered-clock")
}

@Test("Outbox table has new columns from v4 migration")
func outboxTableHasNewColumns() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cols = try journal.read { db in
        let rows = try Row.fetchAll(
            db,
            sql: "PRAGMA table_info(outbox)"
        )
        return rows.compactMap { row -> String? in
            row["name"] as? String
        }
    }

    #expect(cols.contains("card_id"))
    #expect(cols.contains("group_id"))
    #expect(cols.contains("state"))
    #expect(cols.contains("result"))
    #expect(cols.contains("attempt_count"))
}

@Test("acceptOutbox persists drafts and returns them pending with attemptCount 0")
func acceptOutboxPersistsDrafts() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    // Claim Act lease so acceptOutbox can verify it
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft1 = OutboxDraft(
        clientID: UUID(),
        issueID: "ISSUE-1",
        operation: "create_comment",
        payload: "{}"
    )
    let draft2 = OutboxDraft(
        clientID: UUID(),
        issueID: "ISSUE-2",
        operation: "update_description",
        payload: "{\"text\":\"hello\"}"
    )

    let results = try journal.acceptOutbox([draft1, draft2], runID: run, now: epoch)

    #expect(results.count == 2)
    #expect(results[0].clientID == draft1.clientID)
    #expect(results[0].issueID == draft1.issueID)
    #expect(results[0].operation == draft1.operation)
    #expect(results[0].state == .pending)
    #expect(results[0].attemptCount == 0)
    #expect(results[0].cardID == nil)
    #expect(results[0].groupID == nil)

    #expect(results[1].clientID == draft2.clientID)
    #expect(results[1].state == .pending)
    #expect(results[1].attemptCount == 0)
}

@Test("acceptOutbox without Act lease throws actLeaseLost")
func acceptOutboxWithoutActLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let draft = OutboxDraft(
        clientID: UUID(),
        operation: "create_comment",
        payload: "{}"
    )

    #expect(throws: JournalError.actLeaseLost(runID: run, holder: nil)) {
        try journal.acceptOutbox([draft], runID: run, now: epoch)
    }
}

@Test("acceptOutbox is idempotent: same clientID returns existing row unchanged")
func acceptOutboxIdempotent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let clientID = UUID()
    let draft = OutboxDraft(
        clientID: clientID,
        operation: "create_comment",
        payload: "{}"
    )

    let first = try journal.acceptOutbox([draft], runID: run, now: epoch)
    #expect(first.count == 1)
    let firstID = first[0].id

    // Mark it applied to change state
    _ = try journal.markOutboxApplied(id: firstID, result: "success", now: epoch)

    // Accept the same draft again
    let second = try journal.acceptOutbox([draft], runID: run, now: epoch)
    #expect(second.count == 1)
    #expect(second[0].id == firstID)
    #expect(second[0].state == .applied)  // State is unchanged
}

@Test("outboxEntry fetches by clientID")
func outboxEntryByClientID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let clientID = UUID()
    let draft = OutboxDraft(clientID: clientID, operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)

    let fetched = try journal.outboxEntry(clientID: clientID)
    #expect(fetched?.id == entries[0].id)
    #expect(fetched?.clientID == clientID)
}

@Test("outboxEntry fetches by id")
func outboxEntryByID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)

    let fetched = try journal.outboxEntry(id: entries[0].id)
    #expect(fetched?.id == entries[0].id)
}

@Test("pendingOutboxEntries returns only pending, in id order")
func pendingOutboxEntriesFilters() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let ids = try (0..<3).map { index in
        let draft = OutboxDraft(
            clientID: UUID(),
            operation: "op\(index)",
            payload: "{}"
        )
        let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
        return entries[0].id
    }

    _ = try journal.markOutboxApplied(id: ids[1], result: nil, now: epoch)

    let pending = try journal.pendingOutboxEntries()
    #expect(pending.count == 2)
    #expect(pending[0].id == ids[0])
    #expect(pending[1].id == ids[2])
}

@Test("outboxEntries by group_id returns entries with that group")
func outboxEntriesByGroupID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft1 = OutboxDraft(
        clientID: UUID(),
        operation: "op1",
        payload: "{}",
        groupID: "group-a"
    )
    let draft2 = OutboxDraft(
        clientID: UUID(),
        operation: "op2",
        payload: "{}",
        groupID: "group-a"
    )
    let draft3 = OutboxDraft(
        clientID: UUID(),
        operation: "op3",
        payload: "{}",
        groupID: "group-b"
    )

    _ = try journal.acceptOutbox([draft1, draft2, draft3], runID: run, now: epoch)

    let groupA = try journal.outboxEntries(groupID: "group-a")
    #expect(groupA.count == 2)

    let groupB = try journal.outboxEntries(groupID: "group-b")
    #expect(groupB.count == 1)
}
