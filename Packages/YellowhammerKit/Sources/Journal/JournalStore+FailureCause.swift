import Domain
import Foundation
import GRDB

// Failure-Cause Recurrence (loop-state/record-failure-cause-recurrence, roadmap P8.8): the count, held
// against the Card in this Project's Journal, of how many separate Nights met the same failure cause.
// It is this Journal's alone — nothing joins it to a sibling Project's, and nothing moves it into the
// Ledger (ADR-003).

/// One `failure_cause` row: a cause hash counted against a Card across this Project's Nights.
public struct FailureCauseRecord: Equatable, Sendable {
    public let cardID: Int64
    public let causeHash: String
    /// How many separate Nights met this cause. A second failure of the same cause within one Night
    /// does not count again: recurrence spans Nights only (OA16).
    public let recurrenceCount: Int
    public let firstNightID: Int64
    public let lastNightID: Int64

    /// True once the cause has been met on more than one Night: the Card is a design conversation,
    /// not a rerun.
    public var hasRecurred: Bool { recurrenceCount > 1 }
}

/// The most recent failure cause recorded against a Card, as the event log names it.
public struct RecordedFailureCause: Equatable, Sendable {
    public let summary: String
    public let causeHash: String
    public let recurrenceCount: Int

    public var hasRecurred: Bool { recurrenceCount > 1 }
}

extension JournalStore {
    /// Records `cause` against the Card for `nightID` and returns the resulting count, revalidating the
    /// Act's Lease in the same transaction. The first Night inserts the row at 1; a further failure on
    /// the same Night leaves it unchanged; a different Night increments it. Appends
    /// `.failureCauseRecorded` in the same transaction, so the Night Summary can tell a block that was
    /// a recurrence from a first occurrence.
    @discardableResult
    public func recordFailureCause(
        cardID: Int64,
        cause: FailureCause,
        nightID: Int64,
        runID: RunID,
        act: Act? = nil,
        now: Date = Date()
    ) throws -> FailureCauseRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let cardRow = try Row.fetchOne(
                db, sql: "SELECT issue_id FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let issueID: String = cardRow["issue_id"]

            try db.execute(
                sql: """
                INSERT INTO failure_cause (card_id, cause_hash, recurrence_count, first_night_id, last_night_id)
                VALUES (?, ?, 1, ?, ?)
                ON CONFLICT (card_id, cause_hash) DO UPDATE SET
                    recurrence_count = recurrence_count + 1, last_night_id = excluded.last_night_id
                WHERE last_night_id <> excluded.last_night_id
                """,
                arguments: [cardID, cause.hash, nightID, nightID]
            )
            guard let record = try Self.fetchFailureCause(db, cardID: cardID, causeHash: cause.hash) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            let event = JournalEvent.failureCauseRecorded(
                cardID: cardID, issueID: issueID, cause: cause.summary, causeHash: cause.hash,
                recurrenceCount: record.recurrenceCount
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)
            return record
        }
    }

    /// Every failure cause counted against the Card, oldest first Night first.
    public func failureCauses(cardID: Int64) throws -> [FailureCauseRecord] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM failure_cause WHERE card_id = ? ORDER BY first_night_id ASC, cause_hash ASC",
                arguments: [cardID]
            ).map(Self.failureCauseRecord)
        }
    }

    /// The failure cause most recently recorded against the Card, or nil when it never failed.
    public func lastRecordedFailureCause(cardID: Int64) throws -> RecordedFailureCause? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT json_extract(payload, '$.cause') AS cause,
                       json_extract(payload, '$.cause_hash') AS cause_hash,
                       json_extract(payload, '$.recurrence_count') AS recurrence_count
                FROM event
                WHERE type = ? AND json_extract(payload, '$.card_id') = ?
                ORDER BY id DESC LIMIT 1
                """,
                arguments: [JournalEventType.failureCauseRecorded.rawValue, String(cardID)]
            ) else {
                return nil
            }
            let count: String = row["recurrence_count"]
            return RecordedFailureCause(
                summary: row["cause"], causeHash: row["cause_hash"], recurrenceCount: Int(count) ?? 1
            )
        }
    }

    private static func fetchFailureCause(
        _ db: Database, cardID: Int64, causeHash: String
    ) throws -> FailureCauseRecord? {
        try Row.fetchOne(
            db, sql: "SELECT * FROM failure_cause WHERE card_id = ? AND cause_hash = ?",
            arguments: [cardID, causeHash]
        ).map(failureCauseRecord)
    }

    private static func failureCauseRecord(_ row: Row) -> FailureCauseRecord {
        FailureCauseRecord(
            cardID: row["card_id"], causeHash: row["cause_hash"], recurrenceCount: row["recurrence_count"],
            firstNightID: row["first_night_id"], lastNightID: row["last_night_id"]
        )
    }
}
