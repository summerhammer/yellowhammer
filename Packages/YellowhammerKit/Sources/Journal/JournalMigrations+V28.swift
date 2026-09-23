import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Nil means no observation (older Nights); new observations are zero, nonzero or unknown.
    static func addNightOpeningBoardSnapshotColumn(_ db: Database) throws {
        try db.alter(table: "night") { table in
            table.add(column: "opening_ready_state", .text)
            table.add(column: "closing_unanswered_max", .integer)
            table.add(column: "closing_failed_adoptions_max", .integer)
            table.add(column: "closing_author_supplied_citation_count", .integer)
        }
    }
}
