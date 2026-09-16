import Domain
import Foundation
import GRDB

public struct BoardSyncPoint: Equatable, Sendable {
    public let lastSync: Date   // the board's own timestamp, fractional seconds preserved
    public let readAt: Date     // wall clock of the read, whole seconds
    public let runID: RunID?
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

    /// Records a board sync point under the Act-scoped lease. Upserts the single row and returns
    /// the stored BoardSyncPoint. Throws JournalError.actLeaseLost if the lease is not held.
    @discardableResult
    public func recordBoardSync(lastSync: Date, runID: RunID, now: Date = Date()) throws -> BoardSyncPoint {
        try write { db in
            // Revalidate Act lease
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            let storedNow = Self.stored(now)
            let lastSyncText = lastSync.formatted(
                Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            )

            try db.execute(
                sql: """
                INSERT OR REPLACE INTO board_sync (id, last_sync, read_at, run_id)
                VALUES (1, ?, ?, ?)
                """,
                arguments: [lastSyncText, Self.timestamp(storedNow), runID.rawValue]
            )

            return BoardSyncPoint(lastSync: lastSync, readAt: storedNow, runID: runID)
        }
    }

    private static func boardSyncPoint(from row: Row) throws -> BoardSyncPoint {
        let lastSyncText: String = row["last_sync"]
        let readAtText: String = row["read_at"]
        let runIDText: String? = row["run_id"]

        // Parse last_sync with fractional seconds first, fall back to whole seconds
        let lastSync: Date
        do {
            lastSync = try Date(
                lastSyncText,
                strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            )
        } catch {
            do {
                lastSync = try Date(
                    lastSyncText,
                    strategy: Date.ISO8601FormatStyle()
                )
            } catch {
                throw JournalError.boardSyncUnreadable
            }
        }

        let readAt = try Self.date(readAtText) { JournalError.boardSyncUnreadable }
        let runID = runIDText.flatMap { RunID(rawValue: $0) }

        return BoardSyncPoint(lastSync: lastSync, readAt: readAt, runID: runID)
    }
}
