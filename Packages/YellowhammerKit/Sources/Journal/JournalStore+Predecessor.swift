import Domain
import Foundation
import GRDB

/// A predecessor Feature and the repositories its Cycle's Cards touched, as read by the
/// predecessor-ancestry gate (P9.2).
public struct PredecessorFeature: Equatable, Sendable {
    public let feature: FeatureRecord
    /// The distinct repository names this Feature's Cycle's Cards touched, sorted.
    public let touchedRepositories: [String]
}

extension JournalStore {
    /// The most recent Feature that is not in flight (its Cycle is archived, not the open Cycle),
    /// together with the distinct, sorted repository names its Cycle's Cards touched. Nil when there
    /// is no such Feature — the first Night, or every Feature recorded so far is still in flight.
    ///
    /// A Feature with no Cycle at all (an inconsistent Journal, never produced by this engine) is
    /// never returned: a Cycle's `feature_id` is what this joins on.
    public func predecessorFeature() throws -> PredecessorFeature? {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT feature.*, cycle.id AS cycle_id FROM feature
                    JOIN cycle ON cycle.feature_id = feature.id
                    WHERE cycle.archived_at IS NOT NULL
                    ORDER BY feature.id DESC
                    LIMIT 1
                    """
                )
            else {
                return nil
            }
            let feature = try Self.featureRecord(from: row)
            let cycleID: Int64 = row["cycle_id"]
            let repositories = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT repository FROM card WHERE cycle_id = ? ORDER BY repository ASC",
                arguments: [cycleID]
            )
            return PredecessorFeature(feature: feature, touchedRepositories: repositories)
        }
    }

    /// Whether a `predecessorAncestryObserved` event already recorded every one of `repositories` as
    /// merged for `featureIssueID` — the durable record of whether the closure seam has already fired
    /// for this Feature's all-merged pass, surviving process exit (nothing about it is kept in memory).
    public func predecessorAncestryPreviouslyFullyMerged(featureIssueID: String) throws -> Bool {
        try events(ofType: .predecessorAncestryObserved).contains { record in
            guard case .predecessorAncestryObserved(let observed, _, let unmergedRepositories) = record.event else {
                return false
            }
            return observed == featureIssueID && unmergedRepositories.isEmpty
        }
    }
}
