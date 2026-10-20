import Foundation
import GRDB

// What an Outbox entry records of the board it was decided against, and the hash of the Managed Block last
// written (split out of Outbox.swift to keep that file under the length limit).

extension JournalStore {
    /// pending → superseded: never delivered because the board no longer holds the condition that justified
    /// the write (a human moved the issue). The reason is kept in `last_error`.
    @discardableResult
    public func markOutboxSuperseded(id: Int64, reason: String) throws -> OutboxEntry {
        try write { db in
            guard let entry = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            guard entry.state == .pending else {
                throw JournalError.outboxEntryNotPending(id: id, state: entry.state)
            }
            try db.execute(
                sql: "UPDATE outbox SET state = ?, last_error = ? WHERE id = ?",
                arguments: [OutboxEntryState.superseded.rawValue, reason, id]
            )
            guard let updated = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            return updated
        }
    }

    /// Every entry that addresses `issueID` or whose result is `issueID` (the create that made it), oldest first,
    /// in any state: what Yellowhammer itself wrote to the issue, for the condition a new write records.
    public func outboxEntries(forIssue issueID: String) throws -> [OutboxEntry] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE issue_id = ? OR result = ? ORDER BY id ASC",
                arguments: [issueID, issueID]
            ).map { row in try Self.outboxEntry(from: row, id: row["id"]) }
        }
    }

    /// Upsert into the managed_block table (issue_id PK, last_posted_hash, posted_at).
    public func recordManagedBlockPosted(
        issueID: String,
        hash: String,
        now: Date = Date()
    ) throws {
        let now = JournalStore.stored(now)
        try write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO managed_block (issue_id, last_posted_hash, posted_at)
                VALUES (?, ?, ?)
                """,
                arguments: [issueID, hash, JournalStore.timestamp(now)]
            )
        }
    }

    /// Fetch the last posted hash for a managed block by issue_id.
    public func managedBlockLastPostedHash(issueID: String) throws -> String? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT last_posted_hash FROM managed_block WHERE issue_id = ?",
                arguments: [issueID]
            ) else {
                return nil
            }
            return row["last_posted_hash"]
        }
    }
}
