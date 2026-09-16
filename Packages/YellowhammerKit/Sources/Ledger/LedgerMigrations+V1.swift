import GRDB

// These functions belong to migration v1 and are frozen; a later migration must not call them with changes.
extension LedgerMigrations {
    static func createProbeResultTable(_ db: Database) throws {
        try db.create(table: "probe_result") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("cli", .text).notNull()
            table.column("probed_at", .text).notNull()
            table.column("adapter_version", .text).notNull()
            table.column("cli_version", .text).notNull()
            table.column("finding_result_file_on_clean_exit", .text).notNull()
                .check(sql: "finding_result_file_on_clean_exit IN ('passed','failed','not_run')")
            table.column("finding_unattended_dispatch", .text).notNull()
                .check(sql: "finding_unattended_dispatch IN ('passed','failed','not_run')")
            table.column("finding_process_containment", .text).notNull()
                .check(sql: "finding_process_containment IN ('passed','failed','not_run')")
            table.column("verdict", .text).notNull()
                .check(sql: "verdict IN ('passed','failed')")
            table.column("reason", .text)
            // A failed verdict must carry an Operator-facing reason; a passed verdict has nil.
            table.check(sql: "verdict = 'passed' OR reason IS NOT NULL")
        }
        try db.create(index: "idx_probe_result_cli_probed_at", on: "probe_result",
                      columns: ["cli", "probed_at", "id"])
    }
}
