import Domain
import Foundation
import GRDB

// A worker pass's question (roadmap P11.1; spec: bounds/escalate-a-question-to-the-operator): recorded
// before the Card moves to Waiting on You, so the question itself outlives the board write that carries
// it and a later Night (P11.2) can recognise a threaded reply against `comment_client_id`.

/// One `card_question` row.
public struct CardQuestionRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    public let attemptID: Int64
    public let nightID: Int64
    public let question: String
    public let commentClientID: String?
    public let askedAt: Date
}

extension JournalStore {
    /// Records `question` against the Card and its Attempt, and appends `.cardQuestionAsked` in the same
    /// write transaction.
    @discardableResult
    public func recordCardQuestion(
        cardID: Int64,
        attemptID: Int64,
        question: String,
        commentClientID: String?,
        nightID: Int64,
        act: Act? = nil,
        runID: RunID? = nil,
        now: Date = Date()
    ) throws -> CardQuestionRecord {
        try write { db in
            guard let cardRow = try Row.fetchOne(
                db, sql: "SELECT issue_id FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let issueID: String = cardRow["issue_id"]
            let askedAt = Self.timestamp(now)

            try db.execute(
                sql: """
                INSERT INTO card_question (card_id, attempt_id, night_id, question, comment_client_id, asked_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [cardID, attemptID, nightID, question, commentClientID, askedAt]
            )
            let id = db.lastInsertedRowID

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db, .cardQuestionAsked(cardID: cardID, issueID: issueID, attemptID: attemptID), stamp: stamp
            )

            let askedAtDate = try Self.date(askedAt) { JournalError.cardUnknown(cardID: cardID) }
            return CardQuestionRecord(
                id: id, cardID: cardID, attemptID: attemptID, nightID: nightID, question: question,
                commentClientID: commentClientID, askedAt: askedAtDate
            )
        }
    }

    /// The most recently recorded question against the Card, nil when it never asked one.
    public func latestCardQuestion(cardID: Int64) throws -> CardQuestionRecord? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM card_question WHERE card_id = ? ORDER BY id DESC LIMIT 1",
                arguments: [cardID]
            ).map(Self.cardQuestionRecord)
        }
    }

    private static func cardQuestionRecord(_ row: Row) throws -> CardQuestionRecord {
        let askedAtText: String = row["asked_at"]
        let cardID: Int64 = row["card_id"]
        return CardQuestionRecord(
            id: row["id"], cardID: cardID, attemptID: row["attempt_id"], nightID: row["night_id"],
            question: row["question"], commentClientID: row["comment_client_id"],
            askedAt: try date(askedAtText) { JournalError.cardUnknown(cardID: cardID) }
        )
    }
}
