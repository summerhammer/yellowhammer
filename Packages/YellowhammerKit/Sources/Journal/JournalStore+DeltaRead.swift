import Domain
import Foundation
import GRDB

/// Where each root of the Delta Read has been read up to (spec: board-projection /
/// read-board-changes-by-delta, `sync-boundary`). The roots are independent: a comment newer than an
/// unread issue change never moves the issues' cursor past it.
/// One root of a resumable pass: where its pages resume and how far it has been observed.
public struct BoardPassRoot: Codable, Equatable, Sendable {
    /// The `since` the pass started this root with; kept for every resumed request.
    public var since: Date?
    /// The Linear `endCursor` the pass reached; nil before its first page.
    public var after: String?
    /// The root reached `hasNextPage == false`.
    public var done: Bool
    /// The latest board timestamp observed in this root during the pass.
    public var maxObserved: Date?

    public init(since: Date?, after: String? = nil, done: Bool = false, maxObserved: Date? = nil) {
        self.since = since
        self.after = after
        self.done = done
        self.maxObserved = maxObserved
    }
}

/// A Delta Read that hit the request cap, checkpointed (spec: sync-boundary): resumed by the next Act under
/// the same `since` and horizon; the time cursors move only when every root is done.
public struct BoardReadPass: Codable, Equatable, Sendable {
    /// The sync horizon captured when the pass started.
    public var horizon: Date
    public var issues: BoardPassRoot
    public var comments: BoardPassRoot

    public init(horizon: Date, issues: BoardPassRoot, comments: BoardPassRoot) {
        self.horizon = horizon
        self.issues = issues
        self.comments = comments
    }
}

/// What a read does to the checkpoint.
public enum BoardPassChange: Equatable, Sendable {
    case keep
    case set(BoardReadPass)
    case clear
}

public struct BoardSyncPoint: Equatable, Sendable {
    /// The checkpoint of an unfinished pass, if any.
    public let pass: BoardReadPass?
    /// The board's own timestamp the updated-issues root has been read to; nil before it was read.
    public let issuesSynced: Date?
    /// The board's own timestamp the new-comments root has been read to; nil before it was read.
    public let commentsSynced: Date?
    public let readAt: Date     // wall clock of the read, whole seconds
    public let runID: RunID?

    /// The later of the two cursors: the one timestamp that summarises the sync point for an event or a
    /// report. Never what a read starts from.
    public var lastSync: Date? {
        switch (issuesSynced, commentsSynced) {
        case (let issues?, let comments?): max(issues, comments)
        case (let issues?, nil): issues
        case (nil, let comments?): comments
        case (nil, nil): nil
        }
    }
}

/// One board issue as a Delta Read last observed it, kept so a revision a non-owning Act saw is still
/// there for the Act that owns it.
public struct BoardIssueObservation: Equatable, Sendable {
    public let issueID: String
    public let updatedAt: Date
    /// The board copy, JSON: opaque to the Journal.
    public let payload: String
    /// Observed by a read that does not own the Card's build decisions and not yet reconciled by a build Act.
    public let buildPending: Bool

    public init(issueID: String, updatedAt: Date, payload: String, buildPending: Bool = false) {
        self.issueID = issueID
        self.updatedAt = updatedAt
        self.payload = payload
        self.buildPending = buildPending
    }
}

/// A comment a Delta Read recorded: its id and creation time, enough to skip it on a re-read.
public struct BoardCommentObservation: Equatable, Sendable {
    public let commentID: String
    public let createdAt: Date

    public init(commentID: String, createdAt: Date) {
        self.commentID = commentID
        self.createdAt = createdAt
    }
}

/// What one completed Delta Read persists, in one transaction with the cursors it moves.
public struct BoardReadRecord: Equatable, Sendable {
    /// The new cursors; nil leaves that root's cursor where it was.
    public var issuesSynced: Date?
    public var commentsSynced: Date?
    /// Every issue revision this read reconciled (new revisions only; deduplicated ones are already stored).
    public var issues: [BoardIssueObservation]
    /// Every comment this read recorded.
    public var comments: [BoardCommentObservation]
    /// Whether the revisions in `issues` are left pending for a build Act (a non-build read) or not.
    public var leavesBuildPending: Bool
    /// A build Act's read has reconciled every pending observation; clear the flag on all of them.
    public var clearsBuildPending: Bool
    /// Observations older than this are forgotten: the overlap that needs deduplicating is behind them.
    public var forgetsBefore: Date?
    /// The checkpoint after this read.
    public var pass: BoardPassChange

    public init(
        issuesSynced: Date?, commentsSynced: Date?, issues: [BoardIssueObservation],
        comments: [BoardCommentObservation], leavesBuildPending: Bool, clearsBuildPending: Bool,
        forgetsBefore: Date?, pass: BoardPassChange = .keep
    ) {
        self.pass = pass
        self.issuesSynced = issuesSynced
        self.commentsSynced = commentsSynced
        self.issues = issues
        self.comments = comments
        self.leavesBuildPending = leavesBuildPending
        self.clearsBuildPending = clearsBuildPending
        self.forgetsBefore = forgetsBefore
    }
}

extension JournalStore {
    /// Reads the current board sync point, if any.
    public func boardSyncPoint() throws -> BoardSyncPoint? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM board_sync WHERE id = 1") else {
                return nil
            }
            return try Self.boardSyncPoint(from: row)
        }
    }

    /// Persists one completed Delta Read under the Act-scoped lease: the observations first, then the
    /// cursors, in a single transaction, so a cursor never moves past an observation that was not stored
    /// and a crash before this call leaves the cursors where they were. A cursor never moves backwards.
    /// Throws JournalError.actLeaseLost if the lease is not held.
    @discardableResult
    public func recordBoardRead(_ record: BoardReadRecord, runID: RunID, now: Date = Date()) throws -> BoardSyncPoint {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            try Self.storeFeatureBoardObservations(db, record.issues)
            try Self.storeObservations(db, record)

            let existing = try Row.fetchOne(db, sql: "SELECT * FROM board_sync WHERE id = 1")
                .map { try Self.boardSyncPoint(from: $0) }
            let issues = Self.later(record.issuesSynced, existing?.issuesSynced)
            let comments = Self.later(record.commentsSynced, existing?.commentsSynced)
            let storedNow = Self.stored(now)
            let pass: BoardReadPass?
            switch record.pass {
            case .keep: pass = existing?.pass
            case .set(let new): pass = new
            case .clear: pass = nil
            }
            let passText = try pass.map { String(bytes: try JSONEncoder().encode($0), encoding: .utf8) ?? "{}" }
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO board_sync (id, issues_synced, comments_synced, read_pass, read_at, run_id)
                VALUES (1, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    issues.map(Self.syncTimestamp), comments.map(Self.syncTimestamp), passText,
                    Self.timestamp(storedNow), runID.rawValue
                ]
            )
            return BoardSyncPoint(
                pass: pass, issuesSynced: issues, commentsSynced: comments, readAt: storedNow, runID: runID
            )
        }
    }

    /// The observations of one read, before its cursors move: the issue revisions (and the pending flag),
    /// the comment ids, and the forgetting of what the overlap no longer needs.
    private static func storeObservations(_ db: Database, _ record: BoardReadRecord) throws {
        if record.clearsBuildPending {
            try db.execute(sql: "UPDATE board_issue_seen SET build_pending = 0 WHERE build_pending = 1")
        }
        for observation in record.issues {
            try db.execute(
                sql: """
                INSERT INTO board_issue_seen (issue_id, updated_at, payload, build_pending)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (issue_id) DO UPDATE SET
                    updated_at = excluded.updated_at,
                    payload = excluded.payload,
                    build_pending = excluded.build_pending
                WHERE excluded.updated_at > board_issue_seen.updated_at
                """,
                arguments: [
                    observation.issueID, Self.syncTimestamp(observation.updatedAt), observation.payload,
                    record.leavesBuildPending ? 1 : 0
                ]
            )
        }
        for comment in record.comments {
            try db.execute(
                sql: "INSERT OR IGNORE INTO board_comment_seen (comment_id, created_at) VALUES (?, ?)",
                arguments: [comment.commentID, Self.syncTimestamp(comment.createdAt)]
            )
        }
        if let cutoff = record.forgetsBefore {
            let text = Self.syncTimestamp(cutoff)
            try db.execute(sql: "DELETE FROM board_comment_seen WHERE created_at < ?", arguments: [text])
            try db.execute(
                sql: "DELETE FROM board_issue_seen WHERE build_pending = 0 AND updated_at < ?", arguments: [text]
            )
        }
    }

    /// The `updated_at` revision last observed for each of `issueIDs` that has been observed at all.
    public func observedIssueRevisions(_ issueIDs: [String]) throws -> [String: Date] {
        guard !issueIDs.isEmpty else { return [:] }
        return try read { db in
            var revisions: [String: Date] = [:]
            for chunk in stride(from: 0, to: issueIDs.count, by: 500) {
                let ids = Array(issueIDs[chunk..<min(chunk + 500, issueIDs.count)])
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT issue_id, updated_at FROM board_issue_seen WHERE issue_id IN ("
                        + ids.map { _ in "?" }.joined(separator: ",") + ")",
                    arguments: StatementArguments(ids)
                )
                for row in rows {
                    let id: String = row["issue_id"]
                    let text: String = row["updated_at"]
                    revisions[id] = try Self.parseSyncTimestamp(text)
                }
            }
            for id in issueIDs {
                if let observation = try Self.featureBoardObservation(db, issueID: id) {
                    revisions[id] = Self.later(observation.updatedAt, revisions[id])
                }
            }
            return revisions
        }
    }

    /// The board copy a Delta Read last observed for `issueID`, if it is still remembered (observations
    /// older than the overlap are forgotten unless a build Act has yet to reconcile them).
    public func observedIssue(_ issueID: String) throws -> BoardObject? {
        try read { db in
            guard let payload = try String.fetchOne(
                db, sql: "SELECT payload FROM board_issue_seen WHERE issue_id = ?", arguments: [issueID]
            ) else { return nil }
            return try? JSONDecoder().decode(BoardObject.self, from: Data(payload.utf8))
        }
    }

    /// Which of `commentIDs` a Delta Read already recorded.
    public func observedCommentIDs(_ commentIDs: [String]) throws -> Set<String> {
        guard !commentIDs.isEmpty else { return [] }
        return try read { db in
            var seen: Set<String> = []
            for chunk in stride(from: 0, to: commentIDs.count, by: 500) {
                let ids = Array(commentIDs[chunk..<min(chunk + 500, commentIDs.count)])
                let rows = try String.fetchAll(
                    db,
                    sql: "SELECT comment_id FROM board_comment_seen WHERE comment_id IN ("
                        + ids.map { _ in "?" }.joined(separator: ",") + ")",
                    arguments: StatementArguments(ids)
                )
                seen.formUnion(rows)
            }
            return seen
        }
    }

    /// Issue observations a non-owning read left for the build Act, oldest revision first.
    public func buildPendingObservations() throws -> [BoardIssueObservation] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM board_issue_seen WHERE build_pending = 1 ORDER BY updated_at, issue_id"
            ).map { row in
                let text: String = row["updated_at"]
                return BoardIssueObservation(
                    issueID: row["issue_id"], updatedAt: try Self.parseSyncTimestamp(text),
                    payload: row["payload"], buildPending: true
                )
            }
        }
    }

    private static func later(_ new: Date?, _ old: Date?) -> Date? {
        switch (new, old) {
        case (let new?, let old?): max(new, old)
        case (let new?, nil): new
        case (nil, let old): old
        }
    }

    /// The board's own timestamp, fractional seconds preserved, in a form that sorts as text.
    static func syncTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private static func parseSyncTimestamp(_ text: String) throws -> Date {
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) {
            return date
        }
        throw JournalError.boardSyncUnreadable
    }

    private static func boardSyncPoint(from row: Row) throws -> BoardSyncPoint {
        let issuesText: String? = row["issues_synced"]
        let commentsText: String? = row["comments_synced"]
        let readAtText: String = row["read_at"]
        let runIDText: String? = row["run_id"]

        let readAt = try Self.date(readAtText) { JournalError.boardSyncUnreadable }
        let passText: String? = row["read_pass"]
        let pass = try passText.map { text -> BoardReadPass in
            guard let pass = try? JSONDecoder().decode(BoardReadPass.self, from: Data(text.utf8)) else {
                throw JournalError.boardSyncUnreadable
            }
            return pass
        }
        return BoardSyncPoint(
            pass: pass,
            issuesSynced: try issuesText.map(Self.parseSyncTimestamp),
            commentsSynced: try commentsText.map(Self.parseSyncTimestamp),
            readAt: readAt,
            runID: runIDText.flatMap { RunID(rawValue: $0) }
        )
    }
}
