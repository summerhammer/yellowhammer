import Domain
import GRDB

extension JournalStore {
    /// Every persisted footprint id, across the teams this Project's board spans.
    public func boardFootprint() throws -> [BoardFootprintRecord] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT team_id, role, object_id, source FROM board_footprint ORDER BY team_id, role"
            )
                .compactMap { row -> BoardFootprintRecord? in
                    guard let role = BoardMappingRole(rawValue: row["role"]),
                          let source = BoardFootprintSource(rawValue: row["source"]) else { return nil }
                    return BoardFootprintRecord(
                        team: BoardObjectID(rawValue: row["team_id"]), role: role,
                        objectID: BoardObjectID(rawValue: row["object_id"]), source: source
                    )
                }
        }
    }

    /// Records `records`, replacing a held id for the same (team, role). Idempotent.
    public func recordBoardFootprint(_ records: [BoardFootprintRecord]) throws {
        guard !records.isEmpty else { return }
        try write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO board_footprint (team_id, role, object_id, source) VALUES (?, ?, ?, ?)
                        ON CONFLICT (team_id, role)
                        DO UPDATE SET object_id = excluded.object_id, source = excluded.source
                        """,
                    arguments: [
                        record.team.rawValue, record.role.rawValue, record.objectID.rawValue, record.source.rawValue
                    ]
                )
            }
        }
    }
}
