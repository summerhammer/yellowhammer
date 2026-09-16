import GRDB

// These functions belong to migration v5 and are frozen; a later migration must not call them with changes.
extension JournalMigrations {
    /// Creates the board_sync table to track the last Delta Read sync point and adds cancelled_from_state
    /// column to the card table to remember what state a Card held before being marked Cancelled.
    static func addDeltaReadTracking(_ db: Database) throws {
        try db.create(table: "board_sync") { table in
            table.column("id", .integer).primaryKey()
                .check(sql: "id = 1")
            table.column("last_sync", .text).notNull()
            table.column("read_at", .text).notNull()
            table.column("run_id", .text)
        }
        try db.alter(table: "card") { table in
            table.add(column: "cancelled_from_state", .text)
        }
    }
}
