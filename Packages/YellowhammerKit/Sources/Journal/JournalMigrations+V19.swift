import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Records a Repo Lane's opened pull request, once (roadmap P10.4): `url` is nullable because
    /// GitHub reporting `.alreadyOpen` carries no URL — this Port never reads pull request state.
    /// Unique on `(feature_id, repository)` so a first write wins and a pull request is never
    /// duplicated for the same Feature's repository.
    static func addPullRequestTable(_ db: Database) throws {
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
            table.uniqueKey(["feature_id", "repository"])
        }
    }
}
