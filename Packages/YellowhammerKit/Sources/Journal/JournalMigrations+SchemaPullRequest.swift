import GRDB

// The `pull_request` table, split out of JournalMigrations+SchemaFeatureFlow.swift for the file length limit.

extension JournalMigrations {
    /// Records a Repo Lane's opened pull request, once (roadmap P10.4): `url` is nullable because
    /// GitHub reporting `.alreadyOpen` carries no URL; the predecessor gate then reads by head branch (OQ190 item 27).
    /// Unique on `(feature_id, repository)` so a first write wins and a pull request is never
    /// duplicated for the same Feature's repository. The rest is its last observed state (feature-authoring/
    /// select-the-next-feature `#pull-request-read`, OQ190 item 14): null until the first successful read, then
    /// overwritten by each one, never set by Yellowhammer otherwise. `number` comes from the read that found the pull
    /// request; `url` is only ever the land Act's.
    static func createPullRequestTable(_ db: Database) throws {
        try db.create(table: "pull_request") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            table.column("url", .text)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("run_id", .text).notNull()
            table.column("opened_at", .text).notNull()
            table.column("number", .integer)
            table.column("observed_state", .text)
                .check(sql: "observed_state IN ('open','merged','closed_without_merge')")
            table.column("observed_at", .text)
            table.column("head_commit", .text)
            table.column("merge_commit", .text)
            table.column("base_branch", .text)
            table.uniqueKey(["feature_id", "repository"])
        }
    }
}
