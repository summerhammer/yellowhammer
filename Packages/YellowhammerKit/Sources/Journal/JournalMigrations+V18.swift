import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The predecessor gate's own durable state (roadmap P9.9; spec: feature-authoring/
    /// select-the-next-feature, third story): the repositories a Feature touches, recorded at
    /// selection time rather than derived from its Cards (a Card's repository row can disappear —
    /// cancelled, adopted elsewhere — long after the Feature that touched it is a predecessor), the
    /// landings the gate has observed for it, and whether it has been released.
    ///
    /// `feature_repository` is backfilled for every Feature this migration finds, from
    /// `SELECT DISTINCT cycle.feature_id, card.repository` — the best evidence a pre-v18 Journal has.
    /// It is not authoritative for those rows (a Card since removed leaves no trace to backfill from),
    /// only for Features authored from v18 onward, which record it directly at selection.
    static func addFeatureLandingTables(_ db: Database) throws {
        try db.create(table: "feature_repository") { table in
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.primaryKey(["feature_id", "repository"])
        }

        try db.create(table: "feature_landing") { table in
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("mainline_commit", .text).notNull()
            table.column("observed_at", .text).notNull()
            table.primaryKey(["feature_id", "repository"])
        }

        try db.alter(table: "feature") { table in
            table.add(column: "released_at", .text)
        }

        try db.execute(
            sql: """
            INSERT OR IGNORE INTO feature_repository (feature_id, repository)
            SELECT DISTINCT cycle.feature_id, card.repository
            FROM card
            JOIN cycle ON cycle.id = card.cycle_id
            """
        )
    }
}
