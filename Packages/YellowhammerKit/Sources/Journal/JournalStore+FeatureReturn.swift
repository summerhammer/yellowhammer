import Domain
import Foundation
import GRDB

// Records a Feature returned for unmet or unresolved clauses (roadmap P10.6; spec: verification/
// return-a-feature-with-unmet-clauses), once per Feature: first transition wins, so a retried land Act
// (a throw from this seam is a fault, and the Cycle stays unlanded to retry) reuses the same state
// rather than appending a second event.

extension JournalStore {
    /// Sets `featureID`'s state to `returned` (revalidating the Act Lease first, the same way
    /// ``markCycleLanded(cycleID:runID:now:)`` does). Idempotent: a Feature already `returned` is left
    /// untouched and this returns false, so the caller appends the Journal event only on the first
    /// transition.
    @discardableResult
    public func recordFeatureReturned(featureID: Int64, runID: RunID, now: Date = Date()) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard
                let row = try Row.fetchOne(db, sql: "SELECT state FROM feature WHERE id = ?", arguments: [featureID])
            else {
                throw JournalError.featureUnknown(featureID: featureID)
            }
            let state: String = row["state"]
            guard state != "returned" else { return false }

            try db.execute(sql: "UPDATE feature SET state = ? WHERE id = ?", arguments: ["returned", featureID])
            return true
        }
    }
}
