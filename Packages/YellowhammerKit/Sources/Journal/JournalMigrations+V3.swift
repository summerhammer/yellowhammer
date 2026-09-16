import GRDB

// These functions belong to migration v3 and are frozen; a later migration must not call them with changes.
extension JournalMigrations {
    /// A Night closes with a reason, and the set is closed so the schema itself refuses one the
    /// engine does not know. A Night recorded before v3 has no reason until it is closed.
    static func addNightCloseReasonColumn(_ db: Database) throws {
        try db.alter(table: "night") { table in
            table.add(column: "close_reason", .text)
                .check(sql: "close_reason IN ('night_end','opened_and_died','project_removed')")
        }
    }
}
