import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// The Card Reply table (roadmap P11.2; spec: bounds/escalate-a-question-to-the-operator,
    /// board-projection/read-board-changes-by-delta): one human comment the Delta Read classified
    /// against a Card in Waiting on You — an answer to the latest recorded question, a remark, or a
    /// reply to a Divergence notice. Recorded inside the Delta Read's reconciliation, idempotent on
    /// `comment_id`, before the sync point moves. `question_id` is nullable: a Divergence reply, or a
    /// remark recorded against a Card whose latest question row could not be found, carries none.
    /// `applied_at` is set only once the board-side transition and acknowledgement (a separate, later
    /// step) both returned without throwing, so a killed run between recording and applying loses
    /// nothing and a resumed run posts no duplicate acknowledgement.
    static func createCardReplyTable(_ db: Database) throws {
        try db.create(table: "card_reply") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("card_id", .integer).notNull()
                .references("card", column: "id", onDelete: .cascade)
            table.column("question_id", .integer)
                .references("card_question", column: "id")
            table.column("comment_id", .text).notNull().unique()
            table.column("body", .text).notNull()
            table.column("author_name", .text)
            table.column("disposition", .text).notNull()
            table.column("commented_at", .text).notNull()
            table.column("night_id", .integer).notNull()
                .references("night", column: "id")
            table.column("applied_at", .text)
        }
        try db.create(index: "idx_card_reply_card_id", on: "card_reply", columns: ["card_id"])
    }
}
