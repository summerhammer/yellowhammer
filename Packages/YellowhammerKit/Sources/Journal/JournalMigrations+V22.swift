import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Records the Night whose morning a Partial Landing's merge closure concluded (roadmap P10.8;
    /// spec: morning-report/triage-the-morning). Nullable, written at the Operator's settle (P10.9)
    /// or on observing the merge (P10.8) — the one field a closed Night may still change.
    static func addNightTriagedAtColumn(_ db: Database) throws {
        try db.alter(table: "night") { table in
            table.add(column: "triaged_at", .text)
        }
    }
}
