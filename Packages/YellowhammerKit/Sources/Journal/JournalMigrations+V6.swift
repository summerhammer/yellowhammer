import GRDB

// These functions belong to migration v6 and are frozen; a later migration must not call them with changes.
extension JournalMigrations {
    /// A Night's constant-time verdict line, as the Journal records it (OQ13). `idle` is the only
    /// value this phase writes; the schema itself refuses any other, exactly like `close_reason`.
    static func addNightVerdictColumn(_ db: Database) throws {
        try db.alter(table: "night") { table in
            table.add(column: "verdict", .text)
                .check(sql: "verdict IN ('idle')")
        }
    }
}
