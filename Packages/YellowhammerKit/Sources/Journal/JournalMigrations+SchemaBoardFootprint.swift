import GRDB

extension JournalMigrations {
    /// The Delta Read's cursors and the footprint ids: both are what this Project's Journal knows of its board.
    static func createBoardSyncTables(_ db: Database) throws {
        try createBoardSyncTable(db)
        try createBoardFootprintTable(db)
    }

    /// The ids of Yellowhammer's board footprint, per team: the two custom workflow states and the three
    /// `Card Type` labels (board-projection/provision-the-board, P22.8). One row per (team, role). `role`
    /// is a `BoardMappingRole` raw value; `source` is `provisioned` or `mapped`. A later Act
    /// reuses these ids and verifies id and category; a matching name alone is never sufficient.
    static func createBoardFootprintTable(_ db: Database) throws {
        try db.create(table: "board_footprint") { table in
            table.column("team_id", .text).notNull()
            table.column("role", .text).notNull()
            table.column("object_id", .text).notNull()
            table.column("source", .text).notNull()
                .check(sql: "source IN ('provisioned','mapped')")
            table.primaryKey(["team_id", "role"])
        }
    }
}
