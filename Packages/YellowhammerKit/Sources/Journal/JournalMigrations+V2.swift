import GRDB

// These functions belong to migration v2 and are frozen; a later migration must not call them with changes.
extension JournalMigrations {
    /// The Act-scoped lease: at most one Act of this Project runs at a time, one level above the
    /// per-Card `lease`. A single row, so the schema itself refuses two holders. It carries `mode`
    /// so that rehearsal alongside real can be decided on its own later.
    static func createActLeaseTable(_ db: Database) throws {
        try db.create(table: "act_lease") { table in
            table.column("id", .integer).primaryKey().check(sql: "id = 1")
            table.column("act", .text).notNull()
                .check(sql: "act IN ('author','build','land')")
            table.column("run_id", .text).notNull()
            table.column("mode", .text).notNull()
                .check(sql: "mode IN ('real','rehearsal')")
            table.column("claimed_at", .text).notNull()
            table.column("heartbeat_at", .text).notNull()
            table.column("expires_at", .text).notNull()
        }
    }
}
