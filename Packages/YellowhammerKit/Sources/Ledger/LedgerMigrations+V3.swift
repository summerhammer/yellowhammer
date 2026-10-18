import GRDB

// This function belongs to migration v3 and is frozen; a later migration must not call it with changes.
extension LedgerMigrations {
    /// The state-containment finding (issue #557). Nullable: a row recorded before v3 never measured
    /// it, so it stays NULL and reads back as `not_run`.
    static func addStateContainmentColumn(_ db: Database) throws {
        try db.alter(table: "probe_result") { table in
            table.add(column: "finding_state_containment", .text)
                .check(sql: "finding_state_containment IN ('passed','failed','not_run')")
        }
    }
}
