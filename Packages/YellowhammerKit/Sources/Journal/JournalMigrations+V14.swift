import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds an Attempt's preserved-work provenance (Attempt, Block and Reset Ruling 2026-09-19, OQ60):
    /// when a new Attempt or a Block resets the Worktree to the last known-good commit, the prior
    /// Attempt's own commits plus any WIP commit are preserved under a git ref before the reset, and
    /// recorded here against that Attempt — both nullable:
    /// - `preserved_ref` — `refs/yellowhammer/attempts/<feature branch name>/<attempt id>`.
    /// - `preserved_commit` — the Feature Branch tip the ref points at, just before the reset.
    static func addAttemptPreservedRef(_ db: Database) throws {
        try db.alter(table: "attempt") { table in
            table.add(column: "preserved_ref", .text)
            table.add(column: "preserved_commit", .text)
        }
    }
}
