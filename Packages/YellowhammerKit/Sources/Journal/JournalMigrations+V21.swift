import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Records which route closed a Feature (roadmap P10.7; spec: verification/archive-the-cycle-on-a-
    /// verified-feature): `verification` when every Definition of Done clause was met, `merge` when the
    /// Operator merged a Partial Landing (P10.8, not yet built). Nullable — unset until a Feature closes.
    static func addFeatureClosedByColumn(_ db: Database) throws {
        try db.alter(table: "feature") { table in
            table.add(column: "closed_by", .text)
                .check(sql: "closed_by IN ('verification','merge')")
        }
    }
}
