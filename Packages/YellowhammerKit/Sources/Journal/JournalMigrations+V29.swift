import Foundation
import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Salts every Outbox client id this Journal computes (`OutboxClientID.make`) so a Project reset —
    /// Journal deleted, its Linear issues archived — never re-addresses an archived issue on replay. A
    /// fresh Journal (no Outbox entries yet) gets a random salt; a Journal that already has entries keeps
    /// the empty, legacy salt so those entries still resolve by their already-recorded client id.
    static func addOutboxSaltColumn(_ db: Database) throws {
        try db.alter(table: "project_state") { table in
            table.add(column: "outbox_salt", .text).notNull().defaults(to: "")
        }
        let outboxCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        let hasOutboxEntries = outboxCount > 0
        if !hasOutboxEntries {
            let salt = UUID().uuidString.lowercased()
            try db.execute(sql: "UPDATE project_state SET outbox_salt = ? WHERE id = 1", arguments: [salt])
        }
    }
}
