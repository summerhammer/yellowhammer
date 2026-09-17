import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds the Journal-side storage the Readiness Check needs (P8.2): the Architectural Brief's prose,
    /// one row per Card, and the Transcription Block's own content (the renderer's round-trip source),
    /// nullable because a block recorded before this migration ships has none until it is next parsed.
    static func addReadinessCheckTables(_ db: Database) throws {
        try db.create(table: "architectural_brief") { table in
            table.column("card_id", .integer).primaryKey()
                .references("card", column: "id", onDelete: .cascade)
            table.column("prose", .text).notNull()
            table.column("recorded_at", .text).notNull()
        }
        try db.alter(table: "transcription_block") { table in
            table.add(column: "content", .text)
        }
    }
}
