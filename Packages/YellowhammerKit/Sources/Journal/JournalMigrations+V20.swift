import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Records a Cycle's Verification once (roadmap P10.5; spec: verification/verify-a-feature-clause-by-clause).
    /// `feature_verification` is unique on `cycle_id`: a Cycle is judged once, so a retried land Act
    /// reuses the record. `route` is nil when no verifier dispatch was needed. `clause_verification`
    /// snapshots each clause's text, citation and citation provenance as judged, so the report stays as
    /// the verifier saw it however the board's clause is edited later. `judged_by` says whether the
    /// verdict is the verifier's or one the engine decided itself.
    static func addFeatureVerificationTables(_ db: Database) throws {
        try db.create(table: "feature_verification") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("feature_id", .integer).notNull()
                .references("feature", column: "id", onDelete: .cascade)
            table.column("cycle_id", .integer).notNull().unique()
                .references("cycle", column: "id", onDelete: .cascade)
            table.column("route", .text)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("run_id", .text).notNull()
            table.column("verified_at", .text).notNull()
        }
        try db.create(table: "clause_verification") { table in
            table.column("verification_id", .integer).notNull()
                .references("feature_verification", column: "id", onDelete: .cascade)
            table.column("issue_id", .text).notNull()
            table.column("cid", .text).notNull()
            table.column("level", .text).notNull()
                .check(sql: "level IN ('card','feature')")
            table.column("text", .text).notNull()
            table.column("location_id", .text).notNull()
            table.column("citation_provenance", .text).notNull()
                .check(sql: "citation_provenance IN ('machine-found','Author-supplied')")
            table.column("verdict", .text).notNull()
                .check(sql: "verdict IN ('met','unmet','unresolved')")
            table.column("what_was_checked", .text).notNull()
            table.column("interpretation", .text).notNull()
            table.column("invalidated_cause", .text)
                .check(sql: "invalidated_cause IN ('text_edited','citation_edited')")
            table.column("judged_by", .text).notNull()
                .check(sql: "judged_by IN ('agent','engine')")
            table.column("position", .integer).notNull()
            table.primaryKey(["verification_id", "issue_id", "cid"])
        }
    }
}
