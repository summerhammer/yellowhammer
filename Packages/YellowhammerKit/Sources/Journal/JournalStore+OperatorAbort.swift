import Foundation
import GRDB

extension JournalStore {
    /// Records the Operator's request to abort one open Attempt. Returns true when the Attempt is open
    /// (the request is now recorded, whether new or already there), false when it has already ended
    /// (nothing is written). Throws ``JournalError/attemptUnknown(attemptID:)`` for an unknown id.
    ///
    /// Unlike every other Journal write, this does NOT revalidate the Act Lease: the request is the
    /// Operator's, written by `yh stop` from outside the Act that holds the Lease. It changes no loop
    /// state (no Card, Attempt or Lease row); the run that holds the Card Lease is the one that acts on
    /// it, and the Expired Lease Sweep honours it if that run dies first.
    @discardableResult
    public func requestOperatorAbort(attemptID: Int64, now: Date = Date()) throws -> Bool {
        try write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT ended_at FROM attempt WHERE id = ?", arguments: [attemptID]
            ) else {
                throw JournalError.attemptUnknown(attemptID: attemptID)
            }
            let endedAt: String? = row["ended_at"]
            guard endedAt == nil else { return false }
            try db.execute(
                sql: "INSERT OR IGNORE INTO operator_abort_request (attempt_id, requested_at) VALUES (?, ?)",
                arguments: [attemptID, Self.timestamp(now)]
            )
            return true
        }
    }

    /// Records the Operator's request to abort every running Attempt — every open Attempt whose Card
    /// belongs to the in-flight Cycle, the same set the Pulse reads as running — in one write
    /// transaction. Returns the requested Attempt ids in id order, empty when none.
    ///
    /// Like ``requestOperatorAbort(attemptID:now:)``, this does NOT revalidate the Act Lease: the
    /// request is the Operator's, written by `yh stop` from outside the Act that holds the Lease. It
    /// changes no loop state (no Card, Attempt or Lease row); the run that holds the Card Lease is the
    /// one that acts on it, and the Expired Lease Sweep honours it if that run dies first.
    public func requestOperatorAbortOfRunningAttempts(now: Date = Date()) throws -> [Int64] {
        guard let cycleID = try inFlightCycleID() else { return [] }
        return try write { db in
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT attempt.id FROM attempt
                    JOIN card ON card.id = attempt.card_id
                    WHERE card.cycle_id = ? AND attempt.ended_at IS NULL
                    ORDER BY attempt.id ASC
                    """,
                arguments: [cycleID]
            )
            for id in ids {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO operator_abort_request (attempt_id, requested_at) VALUES (?, ?)",
                    arguments: [id, Self.timestamp(now)]
                )
            }
            return ids
        }
    }

    /// Whether the Operator has requested an abort of `attemptID`.
    public func isOperatorAbortRequested(attemptID: Int64) throws -> Bool {
        try read { db in
            try Int.fetchOne(
                db, sql: "SELECT 1 FROM operator_abort_request WHERE attempt_id = ?", arguments: [attemptID]
            ) != nil
        }
    }

    /// One Attempt with its Rounds, nil when it does not exist.
    public func attempt(id: Int64) throws -> AttemptRecord? {
        try read { db in try Self.fetchAttempt(db, attemptID: id) }
    }
}
