import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds `landed_at` to `cycle`, nullable: nil until the land Act lands the Cycle once
    /// (roadmap P10.1; risks OQ8, once per Cycle). Set by
    /// ``JournalStore/markCycleLanded(cycleID:runID:now:)``.
    static func addCycleLandedAtColumn(_ db: Database) throws {
        try db.alter(table: "cycle") { table in
            table.add(column: "landed_at", .text)
        }
    }
}
