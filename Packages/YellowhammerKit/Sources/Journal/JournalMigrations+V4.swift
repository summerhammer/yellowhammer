import GRDB

// These functions belong to migration v4 and are frozen; a later migration must not call them with changes.
extension JournalMigrations {
    /// The Outbox table is extended with state machine columns, Card lease tracking, and group delivery
    /// support for all-or-nothing board write sets. The delivery state machine progresses pending →
    /// applied, failed, or aborted, once per entry. Outbox entries persist delivery history for replay
    /// after a crash.
    static func addOutboxDeliveryColumns(_ db: Database) throws {
        try db.alter(table: "outbox") { table in
            table.add(column: "card_id", .integer)
                .references("card", column: "id", onDelete: .setNull)
            table.add(column: "group_id", .text)
            table.add(column: "state", .text).notNull().defaults(to: "pending")
                .check(sql: "state IN ('pending','applied','failed','aborted')")
            table.add(column: "result", .text)
            table.add(column: "attempt_count", .integer).notNull().defaults(to: 0)
        }
        try db.create(index: "idx_outbox_state", on: "outbox", columns: ["state"])
        try db.create(index: "idx_outbox_group_id", on: "outbox", columns: ["group_id"])
    }
}
