import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds `pushed_commit` to `worktree`, nullable: nil until the Feature Branch has been pushed and
    /// that push recorded. This is the release gate (graph-execution/allocate-a-worktree-per-graph-and-repo):
    /// Orca ADE is asked to remove a Worktree only once this column is set.
    static func addWorktreePushedCommit(_ db: Database) throws {
        try db.alter(table: "worktree") { table in
            table.add(column: "pushed_commit", .text)
        }
    }
}
