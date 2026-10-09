import Foundation
import GRDB

extension JournalStore {
    /// Pending and permanently failed entries, ordered by creation time. Applied and aborted writes are
    /// absent: the Pulse reports only writes that can still mislead the Board's reader.
    public func undeliveredOutboxEntries() throws -> [OutboxEntry] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE state IN (?, ?) ORDER BY created_at ASC, id ASC",
                arguments: [OutboxEntryState.pending.rawValue, OutboxEntryState.failed.rawValue]
            )
            return try rows.map { row in
                let id: Int64 = row["id"]
                return try Self.outboxEntry(from: row, id: id)
            }
        }
    }
}
