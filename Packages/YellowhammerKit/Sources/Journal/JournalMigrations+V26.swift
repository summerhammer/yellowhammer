import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// A failed Adoption's durable Divergence record (roadmap P11.5; spec: feature-authoring/
    /// author-the-cycle-and-card-dag, second story): one row per refusal, so they accumulate rather than
    /// overwrite — a sibling of `refusal`, never reused. `stale_blocks` is JSON-encoded, one entry per
    /// repository whose Transcription Block tested stale, so a single refusal can name more than one.
    static func createAdoptionRefusalTable(_ db: Database) throws {
        try db.create(table: "adoption_refusal") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("feature_name", .text).notNull()
            table.column("stale_blocks", .text).notNull()
            table.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_adoption_refusal_card_id", on: "adoption_refusal", columns: ["card_id"])
    }
}
