import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The Refusal table (roadmap P9.7; glossary: Refusal): a Feature's uncitable-Definition-of-Done
    /// halt (``AuthoringHaltReason/uncitableDefinitionOfDone``), tracked per Feature name because a
    /// Refusal can exist before the Journal has a `feature` row for it — the Feature Issue is created
    /// in Waiting on You before authoring is ever accepted into the Outbox.
    ///
    /// `content` keeps the halt reason's detail so it survives expiry, when the halt itself is no
    /// longer the newest thing recorded against the Feature. `unanswered_nights` and
    /// `last_counted_night_id` are the Night-driven clock (bounds/bound-unanswered-nights): a Night
    /// counts toward it only once, and only when it is not the Night the Refusal opened on. At most one
    /// `open` row exists per Feature name — enforced by a partial unique index, not a table constraint,
    /// because `answered`/`expired`/`standing_item` rows for the same Feature name are expected to pile
    /// up across its lifetime.
    static func createRefusalTable(_ db: Database) throws {
        try db.create(table: "refusal") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_name", .text).notNull()
            table.column("issue_id", .text)
            table.column("state", .text).notNull()
                .check(sql: "state IN ('open','answered','expired','standing_item')")
            table.column("content", .text).notNull()
            table.column("opened_night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("unanswered_nights", .integer).notNull().defaults(to: 0)
            table.column("last_counted_night_id", .integer)
                .references("night", column: "id")
            table.column("consecutive_refusals", .integer).notNull()
            table.column("expired_night_id", .integer)
                .references("night", column: "id")
            table.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_refusal_feature_name", on: "refusal", columns: ["feature_name"])
        // A partial index: GRDB's table-builder DSL has no `WHERE` clause for a unique constraint, so
        // this one is raw SQL, same as the event table's append-only triggers.
        try db.execute(
            sql: "CREATE UNIQUE INDEX idx_refusal_open_per_feature ON refusal(feature_name) WHERE state = 'open'"
        )
    }
}
