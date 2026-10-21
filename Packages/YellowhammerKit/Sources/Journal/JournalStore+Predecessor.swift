import Domain
import Foundation
import GRDB

/// A Feature whose open Cycle has landed (roadmap P9.9, 1f): the in-flight Feature the gate observes
/// ancestry for alongside the Unmerged Feature Stack. A branch freshly cut from mainline is trivially an
/// ancestor of it, so a Cycle that has not yet landed is never read as a landing.
public struct InFlightLandedFeature: Equatable, Sendable {
    public let feature: FeatureRecord
    /// The record of what the Feature was meant to touch (`feature_repository`); it never shrinks.
    public let touchedRepositories: [String]
    /// N: the touched repositories minus those with a recorded No-Pushed-Branch Outcome — the only
    /// repositories the gate tests ancestry over.
    public let pushedRepositories: [String]
}

extension JournalStore {
    /// Archived Features whose abandonment has not yet been named on an authoring pass via
    /// ``JournalEvent/predecessorWalkSkippedReleasedFeature(featureIssueID:)``.
    public func unnamedAbandonedArchivedFeatures() throws -> [FeatureRecord] {
        let named = try events(ofType: .predecessorWalkSkippedReleasedFeature)
        let namedIssueIDs = Set(named.compactMap { record -> String? in
            guard case .predecessorWalkSkippedReleasedFeature(let issueID) = record.event else { return nil }
            return issueID
        })
        return try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT feature.* FROM feature
                JOIN cycle ON cycle.feature_id = feature.id
                WHERE cycle.archived_at IS NOT NULL
                  AND feature.abandoned_at IS NOT NULL
                ORDER BY feature.id DESC
                """
            )
            return try rows.map { try Self.featureRecord(from: $0) }
                .filter { !namedIssueIDs.contains($0.issueID) }
        }
    }

    /// The open Cycle's Feature, only when that Cycle has landed (roadmap P9.9, 1f) — a branch freshly
    /// cut from mainline is trivially an ancestor, so a Cycle that has not landed yet is never observed
    /// as if it might already be a landing. Nil when nothing is in flight, or the in-flight Cycle has
    /// not landed.
    public func inFlightLandedFeature() throws -> InFlightLandedFeature? {
        guard let (feature, cycleID) = try inFlightFeature() else { return nil }
        guard try isCycleLanded(cycleID: cycleID) else { return nil }
        let repositories = try touchedRepositories(featureID: feature.id)
        let pushed = try pushedRepositories(featureID: feature.id)
        return InFlightLandedFeature(feature: feature, touchedRepositories: repositories, pushedRepositories: pushed)
    }

    /// Whether a `predecessorAncestryObserved` event already recorded at least one repository merged and
    /// none unmerged for `featureIssueID` (an observation over no repositories is never "all merged") — the durable record of whether the closure seam has already fired
    /// for this Feature's all-merged pass, surviving process exit (nothing about it is kept in memory).
    public func predecessorAncestryPreviouslyFullyMerged(featureIssueID: String) throws -> Bool {
        try events(ofType: .predecessorAncestryObserved).contains { record in
            guard case .predecessorAncestryObserved(
                let observed, let mergedRepositories, let unmergedRepositories
            ) = record.event else {
                return false
            }
            return observed == featureIssueID && !mergedRepositories.isEmpty && unmergedRepositories.isEmpty
        }
    }

    /// N for an archived Feature: the finalized landing record's pushed set, or none for a Feature the Board
    /// completed (`closed_by = 'completion'`) before its Cycle ever landed — nothing was pushed then.
    /// Shared by the predecessor walk and the Unmerged Feature Stack read.
    static func closedFeaturePushedRepositories(
        _ db: Database, feature: FeatureRecord, landedAt: String?
    ) throws -> [String] {
        feature.closedBy == .completion && landedAt == nil
            ? [] : try pushedRepositories(db, featureID: feature.id)
    }

    static func touchedRepositories(_ db: Database, featureID: Int64) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT repository FROM feature_repository WHERE feature_id = ? ORDER BY repository ASC",
            arguments: [featureID]
        )
    }
}
