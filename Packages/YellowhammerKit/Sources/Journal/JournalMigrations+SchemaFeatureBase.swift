import GRDB

extension JournalMigrations {
    /// `feature_base`, split out of ``createFeatureLandingTables(_:)`` to keep that file under the file
    /// length limit.
    static func createFeatureBaseTable(_ db: Database) throws {
        // The `effective_base(R)` a Feature was authored against, recorded at selection per touched
        // repository (feature-authoring/select-the-next-feature, `#effective-base`: "the base is recorded
        // at selection"). `base_ref` is `refs/yellowhammer/landed/<branch>` when the Feature is stacked on
        // an unmerged Feature in R, else the mainline ref; `base_commit` is the commit that ref resolved
        // to; `stacked_on_feature_id` is that Feature, NULL when the base is mainline. Journal-only.
        try db.create(table: "feature_base") { table in
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id")
            table.column("repository", .text).notNull()
            table.column("base_ref", .text).notNull()
            table.column("base_commit", .text).notNull()
            table.column("stacked_on_feature_id", .integer)
                .references("feature", column: "id")
            table.primaryKey(["feature_id", "repository"])
        }
    }
}
