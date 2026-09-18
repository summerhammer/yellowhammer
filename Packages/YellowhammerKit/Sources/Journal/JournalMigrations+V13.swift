import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds the Journal's storage for a Card's declared scope (bounds/refuse-protected-paths-before-dispatch,
    /// roadmap P8.3): the paths the Card is authored to touch, in authored order, one row per path.
    static func addCardScopeTable(_ db: Database) throws {
        try db.create(table: "card_scope") { table in
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("position", .integer).notNull()
            table.column("path", .text).notNull()
            table.primaryKey(["card_id", "position"])
        }
    }
}
