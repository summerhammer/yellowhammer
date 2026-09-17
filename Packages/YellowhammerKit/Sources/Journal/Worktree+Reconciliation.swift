import Domain
import Foundation
import GRDB

// The Journal writes reconciliation at build Act start needs (loop-state/reconcile-worktrees-at-act-start),
// split out of Worktree.swift to keep it under the file length limit.

extension JournalStore {
    /// Advances the last known-good commit recorded for a Worktree (object-guide:
    /// Worktree.last_known_good_commit): set at allocation, and moved forward here once a Card's work
    /// in this Worktree is judged good, so a later reconciliation reset never rewinds accepted work.
    /// One write transaction, revalidating the Act-scoped lease before writing.
    @discardableResult
    public func recordWorktreeKnownGood(
        id: Int64, commit: String, runID: RunID, now: Date = Date()
    ) throws -> WorktreeRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let existing = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            guard existing.releasedAt == nil else {
                throw JournalError.worktreeReleased(id: id)
            }

            try db.execute(
                sql: "UPDATE worktree SET last_known_good_commit = ? WHERE id = ?",
                arguments: [commit, id]
            )

            guard let record = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            return record
        }
    }

    /// Records the WIP commit a reconciliation wrote in this Worktree, so a retry that dispatches
    /// after it can be handed the WIP commit as context. One write transaction, revalidating the
    /// Act-scoped lease before writing.
    @discardableResult
    public func recordWorktreeWIP(
        id: Int64, commit: String, runID: RunID, now: Date = Date()
    ) throws -> WorktreeRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let existing = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            guard existing.releasedAt == nil else {
                throw JournalError.worktreeReleased(id: id)
            }

            try db.execute(
                sql: "UPDATE worktree SET wip_commit = ? WHERE id = ?",
                arguments: [commit, id]
            )

            guard let record = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            return record
        }
    }

    /// Marks a Worktree lost: reconciliation found its recorded path gone — a ghost Worktree. Sets
    /// both `lost_at` and `released_at` to `now` in the same write: a lost Worktree holds no directory
    /// left to protect, so this deliberately bypasses the pushed-commit release gate
    /// ``releaseWorktree(id:runID:now:)`` enforces, and ``heldWorktree(featureID:repository:)`` stops
    /// returning it — the next allocation for this Feature's repository asks Orca ADE for a fresh one.
    /// One write transaction, revalidating the Act-scoped lease before writing.
    /// Throws `worktreeReleased` if the Worktree was already released (lost or otherwise).
    @discardableResult
    public func recordWorktreeLost(
        id: Int64, runID: RunID, now: Date = Date()
    ) throws -> WorktreeRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let existing = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            guard existing.releasedAt == nil else {
                throw JournalError.worktreeReleased(id: id)
            }

            let lostAt = JournalStore.stored(now)
            try db.execute(
                sql: "UPDATE worktree SET lost_at = ?, released_at = ? WHERE id = ?",
                arguments: [JournalStore.timestamp(lostAt), JournalStore.timestamp(lostAt), id]
            )

            guard let record = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            return record
        }
    }
}
