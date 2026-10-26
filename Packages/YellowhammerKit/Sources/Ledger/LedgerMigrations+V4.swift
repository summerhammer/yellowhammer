import GRDB

// This function belongs to migration v4 and is frozen; a later migration must not call it with changes.
extension LedgerMigrations {
    /// The diagnostic run whose prompt records a Probe Result's dispatches wrote. Nullable: a row
    /// recorded before v4 did not keep it, so it stays NULL and reads back as nil.
    static func addPromptRunIDColumn(_ db: Database) throws {
        try db.alter(table: "probe_result") { table in
            table.add(column: "prompt_run_id", .text)
        }
    }
}
