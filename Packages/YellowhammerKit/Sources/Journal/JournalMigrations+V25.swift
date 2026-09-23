import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The Card side of the unanswered-Nights clock (roadmap P11.4; spec:
    /// bounds/bound-unanswered-nights): `card.unanswered_nights` (dormant since V1) is joined by the
    /// Night it was last counted for, mirroring `refusal.last_counted_night_id` — nullable, because the
    /// Night a Card enters Waiting on You never counts, and a Card that has never been in Waiting on
    /// You has counted none.
    static func addCardUnansweredLastCountedNightColumn(_ db: Database) throws {
        try db.alter(table: "card") { table in
            table.add(column: "unanswered_last_counted_night_id", .integer)
                .references("night", column: "id")
        }
    }
}
