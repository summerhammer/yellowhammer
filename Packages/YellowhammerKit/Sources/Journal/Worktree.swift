import Domain
import Foundation
import GRDB

/// A Worktree held for one Feature's repository. Orca ADE creates, places and cleans up the worktree;
/// Yellowhammer holds only its id and path, here in the Journal and never in memory, so a resumed Act
/// finds the path again.
public struct WorktreeRecord: Equatable, Sendable {
    public let id: Int64
    public let featureID: Int64
    public let repository: String
    public let worktreeID: String
    public let path: String
    public let createdAt: Date
    public let releasedAt: Date?
    /// The commit the Feature Branch was at when it was pushed, nil until then. Releasing (and so
    /// removing) the Worktree is refused while this is nil.
    public let pushedCommit: String?
    /// What a reconciliation reset returns to (object-guide: Worktree.last_known_good_commit): set at
    /// allocation, and advanced by ``JournalStore/recordWorktreeKnownGood(id:commit:runID:now:)`` once a
    /// Card's work is judged good, so a reset never rewinds accepted work.
    public let lastKnownGoodCommit: String?
    /// The WIP commit reconciliation wrote in this Worktree, if any, handed to the retry as context.
    public let wipCommit: String?
    /// When reconciliation found this Worktree's recorded path gone — a ghost Worktree. Nil unless lost.
    public let lostAt: Date?

    /// Whether this Worktree has not yet been released.
    public var isHeld: Bool { releasedAt == nil }
    /// Whether reconciliation found this Worktree's recorded path gone.
    public var isLost: Bool { lostAt != nil }
}

extension JournalStore {
    /// Records a Worktree held for `featureID`'s `repository`. One write transaction, revalidating the
    /// Act-scoped lease before writing.
    @discardableResult
    public func recordWorktree(
        featureID: Int64,
        repository: String,
        worktreeID: String,
        path: String,
        runID: RunID,
        lastKnownGoodCommit: String? = nil,
        now: Date = Date()
    ) throws -> WorktreeRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard try Int.fetchOne(db, sql: "SELECT 1 FROM feature WHERE id = ?", arguments: [featureID]) != nil else {
                throw JournalError.featureUnknown(featureID: featureID)
            }

            let createdAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                INSERT INTO worktree (feature_id, repository, worktree_id, path, created_at, last_known_good_commit)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    featureID, repository, worktreeID, path, JournalStore.timestamp(createdAt), lastKnownGoodCommit
                ]
            )
            let id = db.lastInsertedRowID

            return WorktreeRecord(
                id: id,
                featureID: featureID,
                repository: repository,
                worktreeID: worktreeID,
                path: path,
                createdAt: createdAt,
                releasedAt: nil,
                pushedCommit: nil,
                lastKnownGoodCommit: lastKnownGoodCommit,
                wipCommit: nil,
                lostAt: nil
            )
        }
    }

    /// Records that the Feature Branch held in this Worktree was pushed at `commit`. One write
    /// transaction, revalidating the Act-scoped lease before writing. This is the release gate:
    /// `releaseWorktree` refuses a Worktree that has not been recorded pushed.
    @discardableResult
    public func recordWorktreePush(
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
                sql: "UPDATE worktree SET pushed_commit = ? WHERE id = ?",
                arguments: [commit, id]
            )

            guard let record = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            return record
        }
    }

    /// Releases a held Worktree. One write transaction, revalidating the Act-scoped lease before writing.
    /// Refuses with `worktreeNotPushed` when the Feature Branch has not been recorded pushed: releasing
    /// a Worktree is what lets Orca ADE remove it, and removal must never discard unpushed work — unless
    /// `discardingUnpushedWork` says otherwise (the settle gesture's *released* value, roadmap P10.9:
    /// abandoning the pull requests on our side is never softer than discarding a Worktree that never
    /// got that far).
    @discardableResult
    public func releaseWorktree(
        id: Int64, runID: RunID, discardingUnpushedWork: Bool = false, now: Date = Date()
    ) throws -> WorktreeRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let existing = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            guard existing.releasedAt == nil else {
                throw JournalError.worktreeReleased(id: id)
            }
            guard existing.pushedCommit != nil || discardingUnpushedWork else {
                throw JournalError.worktreeNotPushed(id: id)
            }

            let releasedAt = JournalStore.stored(now)
            try db.execute(
                sql: "UPDATE worktree SET released_at = ? WHERE id = ?",
                arguments: [JournalStore.timestamp(releasedAt), id]
            )

            guard let record = try Self.fetchWorktree(db, id: id) else {
                throw JournalError.worktreeUnknown(id: id)
            }
            return record
        }
    }

    /// The unreleased Worktree recorded for `featureID`'s `repository`, nil when none is held. This is
    /// how allocation decides whether to reuse a Worktree rather than ask Orca ADE for a new one.
    public func heldWorktree(featureID: Int64, repository: String) throws -> WorktreeRecord? {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM worktree
                    WHERE feature_id = ? AND repository = ? AND released_at IS NULL
                    ORDER BY id ASC LIMIT 1
                    """,
                    arguments: [featureID, repository]
                )
            else {
                return nil
            }
            let id: Int64 = row["id"]
            return try Self.fetchWorktree(db, id: id)
        }
    }

    /// All Worktrees recorded for `featureID`, in id order, released ones included: callers filter on
    /// `isHeld`.
    public func worktrees(featureID: Int64) throws -> [WorktreeRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id FROM worktree WHERE feature_id = ? ORDER BY id ASC", arguments: [featureID]
            )
            return try rows.map { row in
                let id: Int64 = row["id"]
                guard let record = try Self.fetchWorktree(db, id: id) else {
                    throw JournalError.worktreeUnreadable(id: id)
                }
                return record
            }
        }
    }

    static func fetchWorktree(_ db: Database, id: Int64) throws -> WorktreeRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM worktree WHERE id = ?", arguments: [id]) else {
            return nil
        }
        let onError = { JournalError.worktreeUnreadable(id: id) }
        let releasedAtText: String? = row["released_at"]
        let lostAtText: String? = row["lost_at"]
        return WorktreeRecord(
            id: id,
            featureID: row["feature_id"],
            repository: row["repository"],
            worktreeID: row["worktree_id"],
            path: row["path"],
            createdAt: try JournalStore.date(row["created_at"], onError: onError),
            releasedAt: try releasedAtText.map { try JournalStore.date($0, onError: onError) },
            pushedCommit: row["pushed_commit"],
            lastKnownGoodCommit: row["last_known_good_commit"],
            wipCommit: row["wip_commit"],
            lostAt: try lostAtText.map { try JournalStore.date($0, onError: onError) }
        )
    }
}
