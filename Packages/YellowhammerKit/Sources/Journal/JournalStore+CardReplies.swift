import Domain
import Foundation
import GRDB

// A human comment on a Card in Waiting on You, classified and recorded inside the Delta Read's
// reconciliation (roadmap P11.2; spec: bounds/escalate-a-question-to-the-operator, board-projection/
// read-board-changes-by-delta), before the sync point moves. Recording is idempotent on the board
// comment id, so a killed run between recording and the board-side apply step loses nothing on replay.
// The apply step (Engine's `WaitingOnYouReplies`) reads `unappliedCardReplies()` and marks each applied
// only once its transition and acknowledgement both returned without throwing.

/// The classification a human comment against a Card in Waiting on You resolved to (G-8): `answer` — a
/// threaded reply to the latest recorded question — `remark` — any other comment against a `question`
/// waiting reason — or `divergence` — any comment against a `divergence` waiting reason. Never decided
/// from the comment's content.
public enum CardReplyDisposition: String, Sendable, Equatable {
    case answer, remark, divergence
}

/// What ``JournalStore/recordCardReply(_:nightID:act:runID:now:)`` writes, bundled so the call stays
/// within SwiftLint's parameter-count limit.
public struct CardReplyDraft: Sendable {
    public let cardID: Int64
    public let issueID: String
    /// The `card_question` this reply was classified against; nil for a Divergence reply, or a remark
    /// recorded against a Card with no recorded question at all.
    public let questionID: Int64?
    public let commentID: String
    public let body: String
    public let authorName: String?
    public let disposition: CardReplyDisposition
    public let commentedAt: Date

    public init(
        cardID: Int64,
        issueID: String,
        questionID: Int64?,
        commentID: String,
        body: String,
        authorName: String?,
        disposition: CardReplyDisposition,
        commentedAt: Date
    ) {
        self.cardID = cardID
        self.issueID = issueID
        self.questionID = questionID
        self.commentID = commentID
        self.body = body
        self.authorName = authorName
        self.disposition = disposition
        self.commentedAt = commentedAt
    }
}

/// One `card_reply` row.
public struct CardReplyRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    /// The `card_question` this reply was classified against; nil for a Divergence reply, or a remark
    /// recorded against a Card with no recorded question at all.
    public let questionID: Int64?
    public let commentID: String
    public let body: String
    public let authorName: String?
    public let disposition: CardReplyDisposition
    public let commentedAt: Date
    public let nightID: Int64
    /// When the board-side apply step (transition, then acknowledgement) completed without throwing;
    /// nil while it is still pending.
    public let appliedAt: Date?
}

extension JournalStore {
    /// Records one classified human comment against `cardID`, and appends `.waitingOnYouReplyRecorded`
    /// in the same transaction — but only on first insert: `comment_id` is UNIQUE, so a replayed Delta
    /// Read (the same comment read again because a crash left the sync point unmoved) is idempotent —
    /// the existing row is returned untouched and no second event is appended.
    @discardableResult
    public func recordCardReply(
        _ draft: CardReplyDraft,
        nightID: Int64,
        act: Act? = nil,
        runID: RunID? = nil,
        now: Date = Date()
    ) throws -> CardReplyRecord {
        try write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO card_reply
                (card_id, question_id, comment_id, body, author_name, disposition, commented_at, night_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    draft.cardID, draft.questionID, draft.commentID, draft.body, draft.authorName,
                    draft.disposition.rawValue, JournalStore.timestamp(draft.commentedAt), nightID
                ]
            )
            let inserted = db.changesCount > 0
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM card_reply WHERE comment_id = ?", arguments: [draft.commentID]
            ) else {
                throw JournalError.cardReplyUnreadable(id: -1)
            }
            if inserted {
                let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
                _ = try Self.insertEvent(
                    db,
                    .waitingOnYouReplyRecorded(
                        cardID: draft.cardID, issueID: draft.issueID, commentID: draft.commentID,
                        disposition: draft.disposition.rawValue
                    ),
                    stamp: stamp
                )
            }
            return try Self.cardReplyRecord(from: row)
        }
    }

    /// Every recorded reply not yet applied, ordered by id ASC — the order the apply step processes
    /// them in, so a killed run's later replies are never applied ahead of its earlier ones.
    public func unappliedCardReplies() throws -> [CardReplyRecord] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM card_reply WHERE applied_at IS NULL ORDER BY id ASC"
            ).map { try Self.cardReplyRecord(from: $0) }
        }
    }

    /// Marks a reply applied: its board-side transition and acknowledgement both returned without
    /// throwing. A no-op (returns the current row) when it is already applied.
    @discardableResult
    public func markCardReplyApplied(id: Int64, now: Date = Date()) throws -> CardReplyRecord {
        let now = JournalStore.stored(now)
        return try write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card_reply WHERE id = ?", arguments: [id]) else {
                throw JournalError.cardReplyUnreadable(id: id)
            }
            if row["applied_at"] == nil {
                try db.execute(
                    sql: "UPDATE card_reply SET applied_at = ? WHERE id = ?",
                    arguments: [JournalStore.timestamp(now), id]
                )
            }
            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM card_reply WHERE id = ?", arguments: [id])
            else {
                throw JournalError.cardReplyUnreadable(id: id)
            }
            return try Self.cardReplyRecord(from: updated)
        }
    }

    /// Every reply recorded against `questionID`, oldest first, optionally narrowed to one disposition —
    /// the reader ``recordCardReply(...)``'s `answer` rows feed to build the resumed dispatch's
    /// ``AnsweredQuestion`` (roadmap P11.2).
    public func cardReplies(questionID: Int64, disposition: CardReplyDisposition? = nil) throws -> [CardReplyRecord] {
        try read { db in
            let rows: [Row]
            if let disposition {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM card_reply WHERE question_id = ? AND disposition = ? ORDER BY id ASC",
                    arguments: [questionID, disposition.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db, sql: "SELECT * FROM card_reply WHERE question_id = ? ORDER BY id ASC", arguments: [questionID]
                )
            }
            return try rows.map { try Self.cardReplyRecord(from: $0) }
        }
    }

    /// How many Nights have elapsed strictly after `nightID` through `throughNightID` inclusive: the
    /// Refusal clock's arithmetic (``advanceRefusalClocks(nightID:unansweredNightsMax:act:runID:now:)``),
    /// generalised to any two Night ids so both the Silence countdown (roadmap P11.2) and the Card
    /// clock (roadmap P11.4) read it from the one place. The Night `nightID` itself never counts.
    public func nightsElapsed(after nightID: Int64, through throughNightID: Int64) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM night WHERE id > ? AND id <= ?",
                arguments: [nightID, throughNightID]
            ) ?? 0
        }
    }

    private static func cardReplyRecord(from row: Row) throws -> CardReplyRecord {
        let id: Int64 = row["id"]
        guard let disposition = CardReplyDisposition(rawValue: row["disposition"] as String) else {
            throw JournalError.cardReplyUnreadable(id: id)
        }
        let commentedAt = try Self.date(row["commented_at"] as String) { JournalError.cardReplyUnreadable(id: id) }
        let appliedAt = try (row["applied_at"] as String?).map { text in
            try Self.date(text) { JournalError.cardReplyUnreadable(id: id) }
        }
        return CardReplyRecord(
            id: id,
            cardID: row["card_id"],
            questionID: row["question_id"],
            commentID: row["comment_id"],
            body: row["body"],
            authorName: row["author_name"],
            disposition: disposition,
            commentedAt: commentedAt,
            nightID: row["night_id"],
            appliedAt: appliedAt
        )
    }
}
