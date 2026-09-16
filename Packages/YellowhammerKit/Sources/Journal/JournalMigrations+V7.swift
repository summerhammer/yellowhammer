import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Card-side state versioning for board projection (roadmap P5.8): `state_version` is bumped by
    /// every Journal-side Card state transition, and `board_state_version` records the version last
    /// confirmed applied on the board — nil until the first confirmed write. Together they are what
    /// ``JournalStore/cardsWithUnpostedState()`` reads to find every Card the board has not caught
    /// up with, so a crashed run's board projection is reposted from the Journal rather than replayed
    /// from the Outbox alone.
    static func addCardStateVersions(_ db: Database) throws {
        try db.alter(table: "card") { table in
            table.add(column: "state_version", .integer).notNull().defaults(to: 0)
            table.add(column: "board_state_version", .integer)
        }
    }
}
