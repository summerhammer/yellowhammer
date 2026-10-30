import GRDB

extension JournalMigrations {
    /// The judged checkouts of a Cycle's Verification (spec: verification/verify-a-feature-clause-by-clause,
    /// `#judged-checkout`; OQ191 items 3, 5 and 7): per repository, the commit judged, the kind of checkout
    /// (`held-worktree` or `fresh-checkout`) and the "no pushed branch" mark. Written in the same transaction as the
    /// verdicts, only when the `feature_verification` row is inserted, so a Cycle's one recorded Verification keeps
    /// the judged checkouts it was written with. A record with no rows here names no judged commit ("judged commit
    /// not recorded"); nothing fills it in later.
    static func createJudgedCheckoutTable(_ db: Database) throws {
        try db.create(table: "judged_checkout") { table in
            table.column("verification_id", .integer).notNull()
                .references("feature_verification", column: "id", onDelete: .cascade)
            table.column("repository", .text).notNull()
            // The full SHA judged: the Pushed Tip, or the recorded base commit when `no_pushed_branch`.
            table.column("commit", .text).notNull()
            table.column("checkout_kind", .text).notNull()
                .check(sql: "checkout_kind IN ('held-worktree','fresh-checkout')")
            table.column("no_pushed_branch", .boolean).notNull()
            table.primaryKey(["verification_id", "repository"])
        }
    }
}
