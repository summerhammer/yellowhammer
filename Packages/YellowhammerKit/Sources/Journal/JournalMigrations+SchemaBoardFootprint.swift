import GRDB

extension JournalMigrations {
    /// The Delta Read's cursors and the footprint ids: both are what this Project's Journal knows of its board.
    static func createBoardSyncTables(_ db: Database) throws {
        try createBoardSyncTable(db)
        try createBoardFootprintTable(db)
        try createLegacyBoardConversionTable(db)
    }

    /// The ids of Yellowhammer's board footprint, per team: the two custom workflow states and the three
    /// `Card Type` labels (board-projection/provision-the-board, P22.8). One row per (team, role). `role`
    /// is a `BoardMappingRole` raw value; `source` is `provisioned`, `mapped` or `bootstrapped`. A later Act
    /// reuses these ids and verifies id and category; a matching name alone is never sufficient.
    static func createBoardFootprintTable(_ db: Database) throws {
        try db.create(table: "board_footprint") { table in
            table.column("team_id", .text).notNull()
            table.column("role", .text).notNull()
            table.column("object_id", .text).notNull()
            table.column("source", .text).notNull()
                .check(sql: "source IN ('provisioned','mapped','bootstrapped')")
            table.primaryKey(["team_id", "role"])
        }
    }

    /// What the legacy Board migration has done per tracked issue (roadmap P22.9; spec: board-projection/
    /// provision-the-board, "Repeatable migration before validation"). One row per (issue, kind): `settle`
    /// (a Feature Card's retired settlement state), `override` (a Work Card's legacy `Override` label,
    /// where `detail` is the pinned Route text) and `project` (the whole migration, keyed by the Project's
    /// sentinel issue id). `version` is the migration's version that wrote the row, so a later version
    /// re-reads rows an older one left. `status` is `planned` (writes accepted, not yet settled), `converted`
    /// (the pin was written to the field), `conflict` (pins and the field disagree; nothing chosen) or
    /// `complete` (nothing left to do, or the Operator resolved it by setting or clearing the field).
    static func createLegacyBoardConversionTable(_ db: Database) throws {
        try db.create(table: "legacy_board_conversion") { table in
            table.column("issue_id", .text).notNull()
            table.column("kind", .text).notNull()
                .check(sql: "kind IN ('settle','override','project')")
            table.column("status", .text).notNull()
                .check(sql: "status IN ('planned','converted','conflict','complete')")
            table.column("detail", .text)
            table.column("version", .integer).notNull()
            table.column("updated_at", .text).notNull()
            table.primaryKey(["issue_id", "kind"])
        }
    }
}
