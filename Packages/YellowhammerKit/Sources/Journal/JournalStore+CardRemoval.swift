import Domain
import Foundation
import GRDB

// A Work Card whose issue the Operator trashed, or archived while it was in play (OQ142; spec:
// board-projection/read-board-changes-by-delta). It inherits Shelve's rules but does not read as Shelved:
// `state` is never touched, so restoring the issue puts the Card back exactly as it stood — counters,
// rounds, Block Reason and budget epoch included.
extension JournalStore {
    /// The board read the Card's issue as removed. Sets `removed_from_board`, ends any open Attempt
    /// `cancelled`, and appends `.cardRemovedFromBoard` in the same write, under the Act-scoped Lease.
    /// Returns the Card unchanged, with no event, when it is already recorded as removed.
    @discardableResult
    public func markCardRemovedFromBoard(
        cardID: Int64,
        how: CardRemoval,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let record = try Self.cardRecord(from: row)
            guard record.removedFromBoard == nil else { return record }

            try db.execute(
                sql: "UPDATE card SET removed_from_board = ? WHERE id = ?", arguments: [how.rawValue, cardID]
            )
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            try Self.cancelOpenAttempt(db, cardID: cardID, issueID: record.issueID, stamp: stamp)
            _ = try Self.insertEvent(
                db, .cardRemovedFromBoard(cardID: cardID, issueID: record.issueID, how: how.rawValue), stamp: stamp
            )
            return record.with(removedFromBoard: how)
        }
    }

    /// The board read a removed Card's issue as restored (un-trashed or unarchived). Clears
    /// `removed_from_board` and appends `.cardRestoredToBoard` in the same write, under the Act-scoped
    /// Lease; nothing else about the Card changes. Returns the Card unchanged, with no event, when it is
    /// not recorded as removed.
    @discardableResult
    public func restoreCardToBoard(
        cardID: Int64,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let record = try Self.cardRecord(from: row)
            guard let how = record.removedFromBoard else { return record }

            try db.execute(sql: "UPDATE card SET removed_from_board = NULL WHERE id = ?", arguments: [cardID])
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db, .cardRestoredToBoard(cardID: cardID, issueID: record.issueID, how: how.rawValue), stamp: stamp
            )
            return record.with(removedFromBoard: nil)
        }
    }
}
