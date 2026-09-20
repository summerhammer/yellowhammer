import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The Authoring Halt as its own object (roadmap P9.8; glossary: Authoring Halt, Refusal): a Feature
    /// whose authoring stopped for a reason that is not a thin specification — no backward-compatible
    /// seam, undeterminable repositories, a repository outside the Project, an unreadable contract.
    /// Tracked per Feature name for the same reason the Refusal is: the Feature Issue exists before any
    /// `feature` row does.
    ///
    /// The clock columns are the Refusal's (bounds/bound-unanswered-nights), and a halt has NO consecutive
    /// count of any kind — only a Refusal counts. At most one `open` row per Feature name, by partial
    /// unique index. A halt has no `answered` state: it clears when that Feature next authors cleanly.
    ///
    /// The Refusal table changes too. Its V15 state CHECK cannot take a new state, so a Refusal a clean
    /// authoring run has closed is marked by `closed_night_id` being non-null, and the one-`open`-row
    /// index is recreated to ignore closed rows (a closed `open` row must not block a fresh one).
    static func createAuthoringHaltTable(_ db: Database) throws {
        try db.create(table: "authoring_halt") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_name", .text).notNull()
            table.column("issue_id", .text)
            table.column("state", .text).notNull()
                .check(sql: "state IN ('open','expired','cleared')")
            table.column("cause_kind", .text).notNull()
            table.column("content", .text).notNull()
            table.column("opened_night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("unanswered_nights", .integer).notNull().defaults(to: 0)
            table.column("last_counted_night_id", .integer)
                .references("night", column: "id")
            table.column("expired_night_id", .integer)
                .references("night", column: "id")
            table.column("created_at", .text).notNull()
        }
        try db.create(index: "idx_authoring_halt_feature_name", on: "authoring_halt", columns: ["feature_name"])
        try db.execute(
            sql: """
            CREATE UNIQUE INDEX idx_authoring_halt_open_per_feature ON authoring_halt(feature_name)
            WHERE state = 'open'
            """
        )

        try db.execute(sql: "ALTER TABLE refusal ADD COLUMN closed_night_id INTEGER REFERENCES night(id)")
        try db.execute(sql: "DROP INDEX idx_refusal_open_per_feature")
        try db.execute(
            sql: """
            CREATE UNIQUE INDEX idx_refusal_open_per_feature ON refusal(feature_name)
            WHERE state = 'open' AND closed_night_id IS NULL
            """
        )
    }
}
