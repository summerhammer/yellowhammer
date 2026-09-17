import GRDB

// This migration is frozen once shipped; a later migration must not call it with changes.
extension JournalMigrations {
    /// Adds the three columns worktree reconciliation needs
    /// (loop-state/reconcile-worktrees-at-act-start), all nullable:
    /// - `last_known_good_commit` — what a reset returns to (object-guide: Worktree.last_known_good_commit),
    ///   set at allocation and advanced later once a Card's work is judged good, so a reset never
    ///   rewinds accepted work.
    /// - `wip_commit` — the WIP commit reconciliation wrote, handed to the retry as context.
    /// - `lost_at` — when reconciliation found the recorded path gone: a ghost Worktree.
    static func addWorktreeReconciliationColumns(_ db: Database) throws {
        try db.alter(table: "worktree") { table in
            table.add(column: "last_known_good_commit", .text)
            table.add(column: "wip_commit", .text)
            table.add(column: "lost_at", .text)
        }
    }
}
