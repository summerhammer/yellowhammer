import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds the Feature Branch name (`yh-<project>-<feature>`) to the `feature` table, nullable: it is
    /// recorded by the author Act in a later phase, so a Feature authored before this migration ships
    /// has none until it is next authored.
    static func addFeatureBranchColumn(_ db: Database) throws {
        try db.alter(table: "feature") { table in
            table.add(column: "branch", .text)
        }
    }
}
