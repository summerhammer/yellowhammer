import GRDB

extension JournalMigrations {
    static func createLandHoldTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE land_hold (
                id INTEGER PRIMARY KEY, night_id INTEGER NOT NULL REFERENCES night(id),
                cycle_id INTEGER NOT NULL REFERENCES cycle(id), card_ids TEXT NOT NULL,
                started_at TEXT NOT NULL, ends_at TEXT NOT NULL, ended_at TEXT, end_reason TEXT,
                answer_wait_minutes INTEGER NOT NULL CHECK(answer_wait_minutes >= 1),
                UNIQUE(night_id, cycle_id, started_at)
            );
            CREATE INDEX land_hold_active ON land_hold(cycle_id, ended_at);
            CREATE TABLE cycle_handoff (cycle_id INTEGER PRIMARY KEY REFERENCES cycle(id));
            CREATE TABLE night_hold_ended (night_id INTEGER PRIMARY KEY REFERENCES night(id));
            """)
    }
}
