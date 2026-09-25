import Domain
import Foundation
import GRDB

// The Card side of board state projection (roadmap P5.8), split out of JournalStore+Cards.swift to
// keep it under the file length limit.

extension JournalStore {
    /// A Journal-side Card state transition: the board projection's write path. One write transaction
    /// under the Act-scoped Lease, in this order — Cancelled is refused both ways (it is read and never
    /// written), an already-cancelled Card is refused (Cancelled takes effect only at the Act boundary
    /// and is never itself transitioned away from here), Waiting on You requires a waiting reason and
    /// Blocked requires a Block Reason (the Journal record is what backs each), leaving either clears
    /// its reason column. A transition to the same state with the same reasons is a no-op: it returns
    /// the current record unchanged, bumps nothing, and logs nothing. Otherwise `state_version` is
    /// bumped by one and `.cardStateTransitioned` is appended in the same transaction.
    @discardableResult
    public func transitionCard(
        cardID: Int64,
        to state: CardState,
        waitingReason: WaitingReason? = nil,
        blockReason: BlockReason? = nil,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> CardRecord {
        guard state != .cancelled else {
            throw JournalError.cancelledIsNeverWritten(cardID: cardID)
        }
        let now = JournalStore.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let record = try Self.cardRecord(from: row)

            guard record.state != .cancelled else {
                throw JournalError.cardAlreadyCancelled(cardID: cardID)
            }
            if state == .waitingOnYou, waitingReason == nil {
                throw JournalError.waitingOnYouUnbacked(cardID: cardID)
            }
            if state == .blocked, blockReason == nil {
                throw JournalError.blockReasonRequired(cardID: cardID)
            }

            let newWaitingReason = state == .waitingOnYou ? waitingReason : nil
            let newBlockReason = state == .blocked ? blockReason : nil

            if record.state == state, record.waitingReason == newWaitingReason,
               record.blockReason == newBlockReason?.rawValue {
                return record
            }

            try Self.writeCardTransition(
                db, record: record, state: state, reasons: (newWaitingReason, newBlockReason), nightID: nightID
            )

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            let event = JournalEvent.cardStateTransitioned(
                cardID: cardID, issueID: record.issueID, from: record.state, to: state,
                waitingReason: newWaitingReason, blockReason: newBlockReason
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)

            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            return try Self.cardRecord(from: updated)
        }
    }

    /// Writes the Card's state row, resetting the unanswered-Nights clock (bounds/bound-unanswered-nights,
    /// roadmap P11.4) when this transition enters Waiting on You afresh — a new question, or a different
    /// waiting reason than the one already held (the divergence route or adoption refusal). Earlier
    /// counters and round history are preserved elsewhere; only this clock restarts. A Card already in
    /// Waiting on You for the same reason (e.g. a repeat remark) leaves the clock untouched. Split out of
    /// ``transitionCard(cardID:to:waitingReason:blockReason:runID:act:nightID:now:)`` to keep that
    /// function within the length limit.
    private static func writeCardTransition(
        _ db: Database, record: CardRecord, state: CardState,
        reasons: (waiting: WaitingReason?, block: BlockReason?), nightID: Int64?
    ) throws {
        let cardID = record.id
        let entersWaitingOnYouAfresh = state == .waitingOnYou
            && (record.state != .waitingOnYou || record.waitingReason != reasons.waiting)

        if entersWaitingOnYouAfresh {
            try db.execute(
                sql: """
                UPDATE card
                SET state = ?, waiting_reason = ?, block_reason = ?, state_version = state_version + 1,
                    unanswered_nights = 0, unanswered_last_counted_night_id = ?
                WHERE id = ?
                """,
                arguments: [
                    state.rawValue, reasons.waiting?.rawValue, reasons.block?.rawValue, nightID, cardID
                ]
            )
        } else {
            try db.execute(
                sql: """
                UPDATE card SET state = ?, waiting_reason = ?, block_reason = ?, state_version = state_version + 1
                WHERE id = ?
                """,
                arguments: [state.rawValue, reasons.waiting?.rawValue, reasons.block?.rawValue, cardID]
            )
        }
    }

    /// Records the Card's `board_state_version` as the version the board has confirmed applied. Under
    /// the Act-scoped Lease. A no-op when the stored value already covers this version or a later one.
    public func recordCardBoardState(
        cardID: Int64,
        version: Int,
        runID: RunID,
        now: Date = Date()
    ) throws {
        let now = JournalStore.stored(now)
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let row = try Row.fetchOne(
                db, sql: "SELECT board_state_version FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let current: Int? = row["board_state_version"]
            if let current, current >= version { return }
            try db.execute(
                sql: "UPDATE card SET board_state_version = ? WHERE id = ?",
                arguments: [version, cardID]
            )
        }
    }

    /// Every Card whose board projection has not caught up with its Journal state: not Cancelled,
    /// transitioned at least once, and either never confirmed on the board or confirmed at an earlier
    /// version. Ordered by id, which is what ``BoardStateProjection/repost()`` replays after a crash.
    ///
    /// A Card at `state_version` 0 never transitioned in the Journal: its authoring group created it on
    /// the board in Todo, so it has no write of its own to post. Reposting Todo for it would overwrite
    /// whatever the Operator did to it on the board before the first build Act read it — a Cancel
    /// among them, which the Delta Read would then never see.
    public func cardsWithUnpostedState() throws -> [CardRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM card
                WHERE state != ? AND state_version > 0
                  AND (board_state_version IS NULL OR board_state_version < state_version)
                ORDER BY id ASC
                """,
                arguments: [CardState.cancelled.rawValue]
            )
            return try rows.map { try Self.cardRecord(from: $0) }
        }
    }
}
