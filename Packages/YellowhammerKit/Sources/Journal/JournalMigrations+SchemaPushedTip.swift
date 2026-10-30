import GRDB

extension JournalMigrations {
    /// The Pushed Tip (spec: feature-authoring/select-the-next-feature, `#pushed-tip`; OQ191 item 2): the commit
    /// the land Act pushed for a Cycle in one repository, pinned in the main clone at
    /// `refs/yellowhammer/landed/<branch>`. Written once per (Cycle, repository) with `INSERT OR IGNORE`, so the
    /// first write wins: a later land firing of the same Cycle never pushes that repository again and never
    /// records it again. A refused push writes no row and is retried. Keyed by Cycle, not by Feature, so whether a
    /// later Cycle of the same Feature may push (OQ193) stays open.
    static func createPushedTipTable(_ db: Database) throws {
        try db.create(table: "pushed_tip") { table in
            table.column("cycle_id", .integer).notNull()
                .references("cycle", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            // The full SHA the push reported.
            table.column("commit", .text).notNull()
            // The land Act run that pushed it.
            table.column("run_id", .text).notNull()
            table.column("pushed_at", .text).notNull()
            table.primaryKey(["cycle_id", "repository"])
        }
    }
}
