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

@Test("markOutboxApplied transitions pending → applied, sets sent_at and result")
func markOutboxAppliedTransitions() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
    let id = entries[0].id

    let before = try journal.outboxEntry(id: id)
    #expect(before?.state == .pending)
    #expect(before?.sentAt == nil)

    let updated = try journal.markOutboxApplied(id: id, result: "success", now: epoch)
    #expect(updated.state == .applied)
    #expect(updated.sentAt == epoch)
    #expect(updated.result == "success")
    #expect(updated.lastError == nil)
}

@Test("markOutboxApplied on non-pending throws outboxEntryNotPending")
func markOutboxAppliedNonPendingThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
    let id = entries[0].id

    _ = try journal.markOutboxApplied(id: id, result: nil, now: epoch)

    #expect(throws: JournalError.outboxEntryNotPending(id: id, state: .applied)) {
        try journal.markOutboxApplied(id: id, result: nil, now: epoch)
    }
}

@Test("markOutboxApplied on unknown id throws outboxEntryUnknown")
func markOutboxAppliedUnknownThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    #expect(throws: JournalError.outboxEntryUnknown(id: 999)) {
        try journal.markOutboxApplied(id: 999, result: nil, now: epoch)
    }
}

@Test("markOutboxFailed transitions pending → failed, sets last_error")
func markOutboxFailedTransitions() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
    let id = entries[0].id

    let updated = try journal.markOutboxFailed(id: id, error: "network error", now: epoch)
    #expect(updated.state == .failed)
    #expect(updated.lastError == "network error")
}

@Test("markOutboxAborted transitions pending → aborted, sets last_error as reason")
func markOutboxAbortedTransitions() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
    let id = entries[0].id

    let updated = try journal.markOutboxAborted(id: id, reason: "lease lost", now: epoch)
    #expect(updated.state == .aborted)
    #expect(updated.lastError == "lease lost")
}

@Test("recordOutboxAttemptFailure increments attempt_count and sets last_error, stays pending")
func recordOutboxAttemptFailureIncrementsAndKeepsPending() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
    let id = entries[0].id

    let before = try journal.outboxEntry(id: id)
    #expect(before?.attemptCount == 0)

    let after1 = try journal.recordOutboxAttemptFailure(id: id, error: "transient")
    #expect(after1.attemptCount == 1)
    #expect(after1.state == .pending)
    #expect(after1.lastError == "transient")

    let after2 = try journal.recordOutboxAttemptFailure(id: id, error: "transient2")
    #expect(after2.attemptCount == 2)
    #expect(after2.state == .pending)
}

@Test("revalidateOutboxLeases with Act lease passes without cardID")
func revalidateOutboxLeasesActLeaseOnly() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)

    let draft = OutboxDraft(clientID: UUID(), operation: "op", payload: "{}")
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)

    // Should not throw
    try journal.revalidateOutboxLeases(for: entries[0], runID: run, now: epoch)
}

@Test("revalidateOutboxLeases with cardID requires Card lease")
func revalidateOutboxLeasesRequiresCardLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")

    let draft = OutboxDraft(
        clientID: UUID(),
        operation: "op",
        payload: "{}",
        cardID: cardID
    )
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)

    // Should throw cardLeaseLost because card lease is not held
    #expect(throws: JournalError.cardLeaseLost(cardID: cardID, runID: run, holder: nil)) {
        try journal.revalidateOutboxLeases(for: entries[0], runID: run, now: epoch)
    }
}

@Test("revalidateOutboxLeases passes with both Act and Card leases held")
func revalidateOutboxLeasesWithBothLeases() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    let draft = OutboxDraft(
        clientID: UUID(),
        operation: "op",
        payload: "{}",
        cardID: cardID
    )
    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)

    // Should not throw
    try journal.revalidateOutboxLeases(for: entries[0], runID: run, now: epoch)
}

@Test("recordManagedBlockPosted upserts into managed_block")
func recordManagedBlockPostedUpserts() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let issueID = "ISSUE-1"
    let hash1 = "abc123"
    let hash2 = "def456"

    let before = try journal.managedBlockLastPostedHash(issueID: issueID)
    #expect(before == nil)

    try journal.recordManagedBlockPosted(issueID: issueID, hash: hash1, now: epoch)
    let after1 = try journal.managedBlockLastPostedHash(issueID: issueID)
    #expect(after1 == hash1)

    try journal.recordManagedBlockPosted(issueID: issueID, hash: hash2, now: epoch)
    let after2 = try journal.managedBlockLastPostedHash(issueID: issueID)
    #expect(after2 == hash2)
}

@Test("Outbox entries with cardID and groupID round-trip")
func outboxCardIDAndGroupIDRoundTrip() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")

    let draft = OutboxDraft(
        clientID: UUID(),
        issueID: "ISSUE-1",
        operation: "update",
        payload: "{}",
        cardID: cardID,
        groupID: "group-x"
    )

    let entries = try journal.acceptOutbox([draft], runID: run, now: epoch)
    let fetched = try journal.outboxEntry(clientID: draft.clientID)

    #expect(fetched?.cardID == cardID)
    #expect(fetched?.groupID == "group-x")
}
