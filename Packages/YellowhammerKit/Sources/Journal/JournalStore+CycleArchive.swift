import Domain
import Foundation
import GRDB

// Archives a Cycle whose Feature was closed (roadmap P10.7; spec: verification/archive-the-cycle-on-a-
// verified-feature), once per Cycle: first transition wins, so a retried land Act (a throw from this
// seam is a fault, and the Cycle stays unarchived to retry) reuses the same state rather than archiving
// twice.

extension JournalStore {
    /// Archives `cycleID` for `featureID`, closed by `closedBy` (revalidating the Act Lease first, the
    /// same way ``markCycleLanded(cycleID:runID:now:)`` does). Sets `cycle.archived_at`,
    /// `feature.closed_by` and `feature.state = 'closed'` in one write transaction. Idempotent: a Cycle
    /// already archived is left untouched and this returns false, so the caller appends the Journal
    /// event only on the first archival. Card rows are never touched here — a Blocked Card's counters,
    /// round history and Block Reason survive for later adoption
    /// (``blockedCardsLeftByClosedFeatures()``).
    @discardableResult
    public func archiveCycle(
        cycleID: Int64, featureID: Int64, closedBy: FeatureClosure, runID: RunID, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            return try Self.archiveCycleRow(db, cycleID: cycleID, featureID: featureID, closedBy: closedBy, now: now)
        }
    }

    /// Sets `cycle.archived_at`, `feature.closed_by` and `feature.state = 'closed'`, once per Cycle —
    /// shared by ``archiveCycle(cycleID:featureID:closedBy:runID:now:)`` (P10.7) and
    /// ``closeFeatureByMerge(_:runID:act:nightID:now:)``
    /// (P10.8), each under its own Act-scoped lease revalidation. Returns whether this call archived
    /// the Cycle; a Cycle already archived is left untouched.
    static func archiveCycleRow(
        _ db: Database, cycleID: Int64, featureID: Int64, closedBy: FeatureClosure, now: Date
    ) throws -> Bool {
        guard
            let cycleRow = try Row.fetchOne(
                db, sql: "SELECT archived_at FROM cycle WHERE id = ?", arguments: [cycleID]
            )
        else {
            throw JournalError.cycleUnknown(cycleID: cycleID)
        }
        guard
            try Int.fetchOne(db, sql: "SELECT 1 FROM feature WHERE id = ?", arguments: [featureID]) != nil
        else {
            throw JournalError.featureUnknown(featureID: featureID)
        }

        let archivedAtText: String? = cycleRow["archived_at"]
        guard archivedAtText == nil else { return false }

        let timestamp = JournalStore.timestamp(JournalStore.stored(now))
        try db.execute(
            sql: "UPDATE cycle SET archived_at = ? WHERE id = ?",
            arguments: [timestamp, cycleID]
        )
        try db.execute(
            sql: "UPDATE feature SET closed_by = ?, state = ? WHERE id = ?",
            arguments: [closedBy.rawValue, "closed", featureID]
        )
        return true
    }
}
