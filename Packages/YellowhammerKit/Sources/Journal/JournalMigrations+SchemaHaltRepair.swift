import GRDB

extension JournalMigrations {
    /// The halted Feature's draft children (roadmap P22.6; spec: feature-authoring/select-the-next-feature,
    /// `#halted-authoring-repair`): one row per Work Card posted as a repairable draft under the Feature Card
    /// (`source` 'authored', its Outbox key and returned issue id persisted before any later write) or admitted
    /// from the Board by the Delta Read (`source` 'board'). A draft is not a Card: it has no `card` row, belongs
    /// to no Cycle, and is never dispatched. `admitted_revision` is the child's exact revision the accepted
    /// result was validated against.
    static func createAuthoringHaltDraftTable(_ db: Database) throws {
        try db.create(table: "authoring_halt_draft") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("halt_id", .integer).notNull()
                .references("authoring_halt", column: "id", onDelete: .cascade)
            table.column("source", .text).notNull()
            table.column("position", .integer).notNull()
            table.column("outbox_key", .text)
            table.column("issue_id", .text)
            table.column("repository", .text)
            table.column("kind", .text)
            table.column("title", .text)
            table.column("observed_at", .text)
            table.column("admitted_revision", .text)
        }
        try db.create(
            index: "authoring_halt_draft_issue", on: "authoring_halt_draft", columns: ["halt_id", "issue_id"],
            unique: true, condition: Column("issue_id") != nil
        )
        try db.create(
            index: "authoring_halt_draft_key", on: "authoring_halt_draft", columns: ["halt_id", "outbox_key"],
            unique: true, condition: Column("outbox_key") != nil
        )
    }
}
