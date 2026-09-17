import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds Attempt-side route provenance for route exclusion on retry
    /// (routing/exclude-tried-routes-on-retry, P7.7), both nullable:
    /// - `route_source` — how the Attempt's Route was selected: `entry` (the Routing Entry's primary
    ///   route), `fallback:<n>` (the entry's nth fallback, 1-based), or `override` (the Operator's pin).
    /// - `override_pin` — the Override pinned in triage at the moment this Attempt was recorded,
    ///   rendered as its `description` (`cli/model/effort`, `-` for an absent axis), or nil when none.
    static func addAttemptRouteProvenance(_ db: Database) throws {
        try db.alter(table: "attempt") { table in
            table.add(column: "route_source", .text)
            table.add(column: "override_pin", .text)
        }
    }
}
