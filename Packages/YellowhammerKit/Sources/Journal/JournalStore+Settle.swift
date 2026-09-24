import Domain
import Foundation
import GRDB

// The Operator's settle gesture (roadmap P10.9; spec: morning-report/triage-the-morning): the Journal
// writes each settle value makes. *unsettled* writes nothing here — the author Act already skips
// authoring while a Feature is in flight, and posts only the keyed ``SettleGestureComment``.

extension JournalStore {
    /// The Night being triaged by a settle write, kept in flight or released alike: the latest Night of
    /// this Project with id less than `currentNightID`, or `currentNightID` itself when there is none
    /// earlier (the Project's first Night). Unlike ``triagedNightID(cycleID:currentNightID:)`` (roadmap
    /// P10.8's merge-closure rule, bounded by the Cycle's landing Night), the settle gesture's own rule
    /// takes no Cycle into account.
    public func settleTriagedNightID(currentNightID: Int64) throws -> Int64 {
        let candidate = try read { db in
            try Int64.fetchOne(
                db, sql: "SELECT id FROM night WHERE project_id = ? AND id < ? ORDER BY id DESC LIMIT 1",
                arguments: [projectID.rawValue, currentNightID]
            )
        }
        return candidate ?? currentNightID
    }

    /// Records the *kept in flight* settle value (roadmap P10.9): sets `night.triaged_at` on
    /// `settle.triagedNightID`, first write wins, and appends `.featureSettled` only when this call is
    /// the one that wrote it — so a second Act of the same Night, recomputing the same
    /// `triagedNightID`, appends nothing further. One write transaction, revalidating the Act Lease
    /// first. No Card or board write: the Feature simply stays in flight.
    @discardableResult
    public func settleFeatureKeptInFlight(
        _ settle: NewFeatureSettled, runID: RunID, act: Act?, nightID: Int64?, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard
                let nightRow = try Row.fetchOne(
                    db, sql: "SELECT triaged_at FROM night WHERE id = ?", arguments: [settle.triagedNightID]
                )
            else {
                throw JournalError.nightUnknown(id: settle.triagedNightID)
            }
            let triagedAtText: String? = nightRow["triaged_at"]
            guard triagedAtText == nil else { return false }

            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try db.execute(
                sql: "UPDATE night SET triaged_at = ? WHERE id = ?", arguments: [timestamp, settle.triagedNightID]
            )

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db,
                .featureSettled(
                    cycleID: settle.cycleID, featureIssueID: settle.featureIssueID,
                    acceptedCards: settle.acceptedCards, triagedNightID: settle.triagedNightID
                ),
                stamp: stamp
            )
            return true
        }
    }

    /// Records the *released* settle value (roadmap P10.9): archives the Cycle (`cycle.archived_at`
    /// only — never `closed_by`, whose CHECK admits only `verification`/`merge`; a released Feature is
    /// re-enterable, not closed), marks the Feature released (`feature.released_at`), sets
    /// `night.triaged_at` on `triagedNightID` (first write wins), and appends `.featureReleased`. One
    /// write transaction, revalidating the Act Lease first. Idempotent on `feature.released_at`: a
    /// Feature already released (by this call or, unreachably in practice since a merge-closed Feature
    /// is no longer in flight, by merge closure) gets no writes and this returns false.
    @discardableResult
    public func settleFeatureReleased(
        _ release: NewFeatureRelease, runID: RunID, act: Act?, nightID: Int64?, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard
                let featureRow = try Row.fetchOne(
                    db, sql: "SELECT released_at FROM feature WHERE id = ?", arguments: [release.featureID]
                )
            else {
                throw JournalError.featureUnknown(featureID: release.featureID)
            }
            let releasedAtText: String? = featureRow["released_at"]
            guard releasedAtText == nil else { return false }

            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try Self.archiveCycleIfUnarchived(db, cycleID: release.cycleID, timestamp: timestamp)
            try db.execute(
                sql: "UPDATE feature SET released_at = ? WHERE id = ?", arguments: [timestamp, release.featureID]
            )
            try Self.stampNightTriagedIfUnset(db, nightID: release.triagedNightID, timestamp: timestamp)

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db,
                .featureReleased(
                    cycleID: release.cycleID, featureIssueID: release.featureIssueID,
                    carriedForward: release.carriedForward, acceptedCards: release.acceptedCards,
                    abandonedRepositories: release.abandonedRepositories, triagedNightID: release.triagedNightID
                ),
                stamp: stamp
            )
            return true
        }
    }

    /// Sets `cycle.archived_at` for `cycleID` if it is still unset — a *released* Feature's Cycle is
    /// archived without `closed_by` (never a closure route; `released_at` is the marker), so this never
    /// reuses ``archiveCycleRow(_:cycleID:featureID:closedBy:now:)``.
    /// Widened from `private` and made `@discardableResult` so
    /// ``JournalStore/recordProjectRemoval(_:runID:now:)`` (P13.5) can archive a decommissioned in-flight
    /// Cycle without duplicating this SQL. Returns whether this call archived the Cycle.
    @discardableResult
    static func archiveCycleIfUnarchived(_ db: Database, cycleID: Int64, timestamp: String) throws -> Bool {
        guard
            let cycleRow = try Row.fetchOne(db, sql: "SELECT archived_at FROM cycle WHERE id = ?", arguments: [cycleID])
        else {
            throw JournalError.cycleUnknown(cycleID: cycleID)
        }
        guard (cycleRow["archived_at"] as String?) == nil else { return false }
        try db.execute(sql: "UPDATE cycle SET archived_at = ? WHERE id = ?", arguments: [timestamp, cycleID])
        return true
    }

    /// Sets `night.triaged_at` for `nightID` if it is still unset — first write wins, shared by both
    /// settle values.
    private static func stampNightTriagedIfUnset(_ db: Database, nightID: Int64, timestamp: String) throws {
        guard
            let nightRow = try Row.fetchOne(db, sql: "SELECT triaged_at FROM night WHERE id = ?", arguments: [nightID])
        else {
            throw JournalError.nightUnknown(id: nightID)
        }
        guard (nightRow["triaged_at"] as String?) == nil else { return }
        try db.execute(sql: "UPDATE night SET triaged_at = ? WHERE id = ?", arguments: [timestamp, nightID])
    }
}

/// Everything recording the *kept in flight* settle value needs, bundled so
/// ``JournalStore/settleFeatureKeptInFlight(_:runID:act:nightID:now:)`` stays under the
/// parameter-count limit.
public struct NewFeatureSettled: Sendable {
    public let cycleID: Int64
    public let featureIssueID: String
    public let acceptedCards: [String]
    public let triagedNightID: Int64

    public init(cycleID: Int64, featureIssueID: String, acceptedCards: [String], triagedNightID: Int64) {
        self.cycleID = cycleID
        self.featureIssueID = featureIssueID
        self.acceptedCards = acceptedCards
        self.triagedNightID = triagedNightID
    }
}

/// Everything releasing a Feature by settle needs, bundled so
/// ``JournalStore/settleFeatureReleased(_:runID:act:nightID:now:)`` stays under the parameter-count limit.
public struct NewFeatureRelease: Sendable {
    public let featureID: Int64
    public let cycleID: Int64
    public let featureIssueID: String
    public let triagedNightID: Int64
    public let carriedForward: [String]
    public let acceptedCards: [String]
    public let abandonedRepositories: [String]

    public init(
        featureID: Int64, cycleID: Int64, featureIssueID: String, triagedNightID: Int64,
        carriedForward: [String], acceptedCards: [String], abandonedRepositories: [String]
    ) {
        self.featureID = featureID
        self.cycleID = cycleID
        self.featureIssueID = featureIssueID
        self.triagedNightID = triagedNightID
        self.carriedForward = carriedForward
        self.acceptedCards = acceptedCards
        self.abandonedRepositories = abandonedRepositories
    }
}
