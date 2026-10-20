import Domain
import Foundation
import GRDB

// A Feature Card's native disposition (roadmap P10.9, P22.2; spec: morning-report/triage-the-morning):
// the Journal writes *completed* (native Done) and *canceled* make. Every other disposition writes
// nothing here — the Feature simply stays in flight.

extension JournalStore {
    /// The Night being triaged by a Cancelled settle write: the latest Night of
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

    /// Records a Feature Card's native Done (roadmap P22.2; spec: morning-report/triage-the-morning):
    /// archives the Cycle with `closed_by = 'completion'` (and `feature.state = 'closed'`) and appends
    /// `.cycleArchived` then `.featureCompleted`. One write transaction, revalidating the Act Lease first.
    /// Never sets `night.triaged_at`: a standing native state does not mark a Night human-triaged.
    /// Idempotent: a Cycle already archived (by this call, or by merge or Verification) is left untouched
    /// and this returns false, appending nothing.
    @discardableResult
    public func settleFeatureCompleted(
        _ completion: NewFeatureCompletion, runID: RunID, act: Act?, nightID: Int64?, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard try Self.archiveCycleRow(
                db, cycleID: completion.cycleID, featureID: completion.featureID, closedBy: .completion, now: now
            ) else {
                return false
            }
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db,
                .cycleArchived(
                    cycleID: completion.cycleID, featureIssueID: completion.featureIssueID, closedBy: .completion,
                    detachedCards: completion.detachedCards
                ),
                stamp: stamp
            )
            _ = try Self.insertEvent(
                db,
                .featureCompleted(
                    cycleID: completion.cycleID, featureIssueID: completion.featureIssueID,
                    carriedForward: completion.carriedForward, acceptedCards: completion.acceptedCards,
                    keptWorktrees: completion.keptWorktrees
                ),
                stamp: stamp
            )
            return true
        }
    }

    /// Records the *abandoned* settle value (roadmap P10.9; OQ128): archives the Cycle (`cycle.archived_at`
    /// only — never `closed_by`, whose CHECK admits only `verification`/`merge`; an abandoned Feature is
    /// re-enterable, not closed), marks the Feature abandoned (`feature.abandoned_at`), sets
    /// `night.triaged_at` on `triagedNightID` (first write wins), and appends `.featureReleased`. One
    /// write transaction, revalidating the Act Lease first. Idempotent on `feature.abandoned_at`: a
    /// Feature already abandoned (by this call or, unreachably in practice since a merge-closed Feature
    /// is no longer in flight, by merge closure) gets no writes and this returns false.
    @discardableResult
    public func settleFeatureReleased(
        _ release: NewFeatureRelease, runID: RunID, act: Act?, nightID: Int64?, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard
                let featureRow = try Row.fetchOne(
                    db, sql: "SELECT abandoned_at FROM feature WHERE id = ?", arguments: [release.featureID]
                )
            else {
                throw JournalError.featureUnknown(featureID: release.featureID)
            }
            let abandonedAtText: String? = featureRow["abandoned_at"]
            guard abandonedAtText == nil else { return false }

            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try Self.archiveCycleIfUnarchived(db, cycleID: release.cycleID, timestamp: timestamp)
            try db.execute(
                sql: "UPDATE feature SET abandoned_at = ? WHERE id = ?", arguments: [timestamp, release.featureID]
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

    /// Sets `cycle.archived_at` for `cycleID` if it is still unset — an *abandoned* Feature's Cycle is
    /// archived without `closed_by` (never a closure route; `abandoned_at` is the marker), so this never
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

    /// Sets `night.triaged_at` for `nightID` if it is still unset — first write wins.
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

/// Everything recording a Feature's native completion needs, bundled so
/// ``JournalStore/settleFeatureCompleted(_:runID:act:nightID:now:)`` stays under the parameter-count limit.
public struct NewFeatureCompletion: Sendable {
    public let featureID: Int64
    public let cycleID: Int64
    public let featureIssueID: String
    public let carriedForward: [String]
    public let acceptedCards: [String]
    public let keptWorktrees: [String]
    public let detachedCards: Int

    public init(
        featureID: Int64, cycleID: Int64, featureIssueID: String, carriedForward: [String],
        acceptedCards: [String], keptWorktrees: [String], detachedCards: Int
    ) {
        self.featureID = featureID
        self.cycleID = cycleID
        self.featureIssueID = featureIssueID
        self.carriedForward = carriedForward
        self.acceptedCards = acceptedCards
        self.keptWorktrees = keptWorktrees
        self.detachedCards = detachedCards
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
