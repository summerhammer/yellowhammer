import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// A Card's board title, so the Roll-up and the partial-landing PR body can name a Card that did
    /// not complete by title instead of by issue id (issue #161; spec:
    /// landing/announce-a-partial-landing). Nullable: every Card authored before V30 has no recorded
    /// title until the Delta Read next reconciles it against the board.
    static func addCardTitleColumn(_ db: Database) throws {
        try db.alter(table: "card") { table in
            table.add(column: "title", .text)
        }
    }
}
