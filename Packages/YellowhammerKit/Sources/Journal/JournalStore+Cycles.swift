import Domain
import Foundation
import GRDB

extension JournalStore {
    /// Marks `cycleID` landed (roadmap P10.1; risks OQ8, once per Cycle): sets `cycle.landed_at`, in one
    /// write transaction that revalidates the Act-scoped lease first, the same way
    /// ``releaseWorktree(id:runID:now:)`` does. A returned Feature's Cycle is marked landed too: landing
    /// is not reversed by a failed verification (spec: landing/overview;
    /// verification/return-a-feature-with-unmet-clauses; issue #695). Idempotent-safe: a Cycle already landed
    /// throws ``JournalError/cycleAlreadyLanded(cycleID:)`` rather than landing it twice. Appends nothing
    /// itself — the land Act appends `.cycleLanded` in the same pass.
    public func markCycleLanded(cycleID: Int64, runID: RunID, now: Date = Date()) throws {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT landed_at FROM cycle WHERE id = ?", arguments: [cycleID]
                )
            else {
                throw JournalError.cycleUnknown(cycleID: cycleID)
            }
            let landedAtText: String? = row["landed_at"]
            guard landedAtText == nil else {
                throw JournalError.cycleAlreadyLanded(cycleID: cycleID)
            }

            try db.execute(
                sql: "UPDATE cycle SET landed_at = ? WHERE id = ?",
                arguments: [JournalStore.timestamp(JournalStore.stored(now)), cycleID]
            )
        }
    }

    /// Whether `cycleID` has already been landed once (whichever way Verification decided: Feature
    /// returned or Cycle archived; issue #695).
    public func isCycleLanded(cycleID: Int64) throws -> Bool {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT landed_at FROM cycle WHERE id = ?", arguments: [cycleID]
                )
            else {
                throw JournalError.cycleUnknown(cycleID: cycleID)
            }
            let landedAtText: String? = row["landed_at"]
            return landedAtText != nil
        }
    }
}
