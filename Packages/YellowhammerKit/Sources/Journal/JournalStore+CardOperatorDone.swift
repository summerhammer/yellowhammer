import Domain
import Foundation
import GRDB

// Operator Done (spec: board-projection / operator-done; ruling OQ199, 2026-11-08): a Work Card the board
// shows in a completed-type state the Journal did not write. The marker is the `.cardOperatorDone` event,
// not a card column.
extension JournalStore {
    /// The board read the Card in a completed-type state the Operator moved it to. In one write transaction,
    /// under the Act-scoped Lease: sets state = Done, clears the waiting reason and Block Reason, bumps
    /// `state_version` and confirms that version as the board's own (the board already holds a completed
    /// state, so the Done is not reposted over it), ends any open Attempt `cancelled`, and appends
    /// `.cardOperatorDone` carrying the previous state, waiting reason and Block Reason. Counters and
    /// history are untouched. In the same transaction, each of `abortingOutboxEntryIDs` still pending is
    /// aborted with `abortReason` — the caller's pending state writes, which must never reach a board that
    /// already holds the Operator's Done, even across a crash. An entry no longer pending (an earlier pass
    /// superseded it) is left as it is.
    /// Throws JournalError.cardAlreadyDone(cardID:) when the Card already is Done.
    @discardableResult
    public func markCardOperatorDone(
        cardID: Int64,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        abortingOutboxEntryIDs: [Int64] = [],
        abortReason: String = "the Operator moved the Card to Done; the state write was not delivered",
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let record = try Self.cardRecord(from: row)
            guard record.state != .done else {
                throw JournalError.cardAlreadyDone(cardID: cardID)
            }

            try db.execute(
                sql: """
                UPDATE card
                SET state = ?, waiting_reason = NULL, block_reason = NULL, shelved_from_state = NULL,
                    state_version = state_version + 1, board_state_version = state_version + 1
                WHERE id = ?
                """,
                arguments: [CardState.done.rawValue, cardID]
            )

            for entryID in abortingOutboxEntryIDs {
                try db.execute(
                    sql: "UPDATE outbox SET state = ?, last_error = ? WHERE id = ? AND state = ?",
                    arguments: [
                        OutboxEntryState.aborted.rawValue, abortReason, entryID, OutboxEntryState.pending.rawValue
                    ]
                )
            }

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            try Self.cancelOpenAttempt(db, cardID: cardID, issueID: record.issueID, stamp: stamp)
            _ = try Self.insertEvent(db, .cardOperatorDone(
                cardID: cardID, issueID: record.issueID, previousState: record.state,
                waitingReason: record.waitingReason,
                blockReason: record.blockReason.flatMap { BlockReason(rawValue: $0) }
            ), stamp: stamp)

            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            return try Self.cardRecord(from: updated)
        }
    }

    /// Whether the Card is Done by the Operator: it is Done, and the latest event that moved it into Done is
    /// `.cardOperatorDone` rather than a Yellowhammer transition. A Card that has left Done since (a Journal
    /// transition away) is not Operator Done.
    public func isOperatorDone(cardID: Int64) throws -> Bool {
        try read { db in
            guard let state: String = try String.fetchOne(
                db, sql: "SELECT state FROM card WHERE id = ?", arguments: [cardID]
            ), state == CardState.done.rawValue else { return false }
            let latest: String? = try String.fetchOne(
                db,
                sql: """
                SELECT type FROM event
                WHERE json_extract(payload, '$.card_id') = ?
                  AND (type = ? OR (type = ? AND json_extract(payload, '$.to_state') = ?))
                ORDER BY id DESC LIMIT 1
                """,
                arguments: [
                    String(cardID), JournalEventType.cardOperatorDone.rawValue,
                    JournalEventType.cardStateTransitioned.rawValue, CardState.done.rawValue
                ]
            )
            return latest == JournalEventType.cardOperatorDone.rawValue
        }
    }
}
