import Domain
import Foundation
import GRDB

// Closure by merge (roadmap P10.8; spec: landing/announce-a-partial-landing, morning-report/
// triage-the-morning): when the predecessor-ancestry gate first observes every touched repository
// merged, the Feature is closed unverified. Closing writes what the Operator's settle (P10.9, not yet
// built) would have written for the Night the merge concluded — its `triaged` flag — possibly inside a
// later Night's span, per the triaged-Night rule below.

extension JournalStore {
    /// The Feature's 1:1 Cycle, archived or not; nil for a Feature the Journal never gave one (never
    /// produced by this engine).
    public func cycleID(featureID: Int64) throws -> Int64? {
        try read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM cycle WHERE feature_id = ?", arguments: [featureID])
        }
    }

    /// The Night id stamped on `cycleID`'s `cycleLanded` event, or nil when the Cycle has no recorded
    /// landing (an inconsistent Journal never produced by this engine, or a Cycle read before landing).
    func cycleLandedNightID(cycleID: Int64) throws -> Int64? {
        try events(ofType: .cycleLanded).first { record in
            if case .cycleLanded(let id) = record.event { return id == cycleID }
            return false
        }?.nightID
    }

    /// The triaged-Night rule (roadmap P10.8; spec: morning-report/triage-the-morning): the Night whose
    /// morning the merge concluded is the latest Night of this Project with id less than the observing
    /// Night's and no earlier than the Night that landed the Cycle. The predecessor-ancestry pass runs
    /// every Night, so the merge became observable only after the previous pass — every Night between
    /// the landing and this observation passed with its morning unmerged, and is never reported as
    /// triaged. With no recorded landing (or the Cycle landed in the observing Night itself), there is
    /// no such earlier Night, and the observing Night is the one triaged.
    public func triagedNightID(cycleID: Int64, currentNightID: Int64) throws -> Int64 {
        guard let landingNightID = try cycleLandedNightID(cycleID: cycleID) else { return currentNightID }
        let candidate = try read { db in
            try Int64.fetchOne(
                db,
                sql: """
                SELECT id FROM night WHERE project_id = ? AND id < ? AND id >= ? ORDER BY id DESC LIMIT 1
                """,
                arguments: [projectID.rawValue, currentNightID, landingNightID]
            )
        }
        return candidate ?? currentNightID
    }

    /// Closes `featureID` by merge (roadmap P10.8), revalidating the Act Lease first, the same way
    /// ``archiveCycle(cycleID:featureID:closedBy:runID:now:)`` does. One write transaction: archives the
    /// Cycle (`closed_by = 'merge'`), sets `night.triaged_at` on `triagedNightID` only if it is still
    /// unset — first write wins, so a later Night's settle (P10.9) never overwrites what this call
    /// recorded — and appends `.cycleArchived` then `.featureClosedByMerge` in the same pass. Idempotent:
    /// a Cycle already archived is left untouched and this returns false, appending nothing — the caller
    /// (``FeatureMergeClosure``) still retries its board writes on every call, keyed so a retry re-queues
    /// rather than duplicates.
    @discardableResult
    public func closeFeatureByMerge(
        _ closure: NewFeatureMergeClosure, runID: RunID, act: Act?, nightID: Int64?, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            let firstArchive = try Self.archiveCycleRow(
                db, cycleID: closure.cycleID, featureID: closure.featureID, closedBy: .merge, now: now
            )
            guard firstArchive else { return false }

            guard
                let nightRow = try Row.fetchOne(
                    db, sql: "SELECT triaged_at FROM night WHERE id = ?", arguments: [closure.triagedNightID]
                )
            else {
                throw JournalError.nightUnknown(id: closure.triagedNightID)
            }
            let triagedAtText: String? = nightRow["triaged_at"]
            if triagedAtText == nil {
                let timestamp = JournalStore.timestamp(JournalStore.stored(now))
                try db.execute(
                    sql: "UPDATE night SET triaged_at = ? WHERE id = ?",
                    arguments: [timestamp, closure.triagedNightID]
                )
            }

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            _ = try Self.insertEvent(
                db,
                .cycleArchived(
                    cycleID: closure.cycleID, featureIssueID: closure.featureIssueID, closedBy: .merge,
                    detachedCards: closure.detachedCards
                ),
                stamp: stamp
            )
            _ = try Self.insertEvent(
                db,
                .featureClosedByMerge(
                    cycleID: closure.cycleID, featureIssueID: closure.featureIssueID,
                    repositories: closure.mergedRepositories, carriedForward: closure.carriedForward,
                    acceptedCards: closure.acceptedCards, triagedNightID: closure.triagedNightID
                ),
                stamp: stamp
            )
            return true
        }
    }
}

/// Everything closing a Feature by merge needs, bundled so
/// ``JournalStore/closeFeatureByMerge(_:runID:act:nightID:now:)`` stays under the parameter-count limit.
public struct NewFeatureMergeClosure: Sendable {
    public let featureID: Int64
    public let cycleID: Int64
    public let featureIssueID: String
    public let triagedNightID: Int64
    public let mergedRepositories: [String]
    public let carriedForward: [String]
    public let acceptedCards: [String]
    public let detachedCards: Int

    public init(
        featureID: Int64, cycleID: Int64, featureIssueID: String, triagedNightID: Int64,
        mergedRepositories: [String], carriedForward: [String], acceptedCards: [String], detachedCards: Int
    ) {
        self.featureID = featureID
        self.cycleID = cycleID
        self.featureIssueID = featureIssueID
        self.triagedNightID = triagedNightID
        self.mergedRepositories = mergedRepositories
        self.carriedForward = carriedForward
        self.acceptedCards = acceptedCards
        self.detachedCards = detachedCards
    }
}
