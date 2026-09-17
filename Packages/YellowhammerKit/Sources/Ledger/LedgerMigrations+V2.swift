import GRDB

// This function belongs to migration v2 and is frozen; a later migration must not call it with changes.
extension LedgerMigrations {
    static func addSessionResumptionColumn(_ db: Database) throws {
        try db.alter(table: "probe_result") { table in
            table.add(column: "finding_session_resumption", .text)
                .notNull()
                .defaults(to: "not_run")
                .check(sql: "finding_session_resumption IN ('passed','failed','not_run')")
        }
    }
}
