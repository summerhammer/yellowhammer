import GRDB

// This function belongs to migration v5 and is frozen; a later migration must not call it with changes.
extension LedgerMigrations {
    /// The session-naming finding (issue #800). Nullable: a row recorded before v5 never measured it, so
    /// it stays NULL and reads back as `not_run`.
    static func addSessionNamingColumn(_ db: Database) throws {
        try db.alter(table: "probe_result") { table in
            table.add(column: "finding_session_naming", .text)
                .check(sql: "finding_session_naming IN ('passed','failed','not_run')")
        }
    }
}
