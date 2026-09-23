import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The Card Question table (roadmap P11.1; spec: bounds/escalate-a-question-to-the-operator): a
    /// worker pass's question, recorded before the Card moves to Waiting on You. `comment_client_id` is
    /// the Outbox client id the question comment is posted under, nullable when there was no Outbox to
    /// post through, so a later Night (P11.2) can recognise a threaded reply to it.
    static func createCardQuestionTable(_ db: Database) throws {
        try db.create(table: "card_question") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("attempt_id", .integer).notNull()
                .references("attempt", column: "id", onDelete: .cascade)
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("question", .text).notNull()
            table.column("comment_client_id", .text)
            table.column("asked_at", .text).notNull()
        }
        try db.create(index: "idx_card_question_card_id", on: "card_question", columns: ["card_id"])
    }
}
