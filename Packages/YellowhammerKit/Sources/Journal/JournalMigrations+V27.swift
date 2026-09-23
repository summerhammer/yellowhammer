import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The refusal-drift and Divergence promotion Bounds' markers (roadmap P11.6; bounds overview):
    /// visibility only, so neither is a state, a counter or a budget. `refusal.standing_item_night_id`
    /// is set once, the Night a Refusal's consecutive count first exceeds `consecutive_refusals_max` —
    /// it never moves `refusal.state`, which the Unanswered Position Clock and the answer path still
    /// select on. `card.divergence_standing_night_id` is the same marker for a Card whose
    /// `failed_adoptions` first exceeds `failed_adoptions_max`. Both are cleared wherever their count
    /// resets, so a fresh count after a clean run starts unpromoted.
    static func addStandingItemColumns(_ db: Database) throws {
        try db.alter(table: "refusal") { table in
            table.add(column: "standing_item_night_id", .integer)
                .references("night", column: "id")
        }
        try db.alter(table: "card") { table in
            table.add(column: "divergence_standing_night_id", .integer)
                .references("night", column: "id")
        }
    }
}
