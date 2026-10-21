import Domain
import Foundation
import GRDB

/// A predecessor Feature and the repositories its Cycle touches (roadmap P9.9), as read by the
/// predecessor-ancestry gate (P9.2). A Feature closed by native completion (`closed_by = 'completion'`,
/// roadmap P22.2) is a predecessor like a verified or merged one; only an abandoned Feature is walked past.
public struct PredecessorFeature: Equatable, Sendable {
    public let feature: FeatureRecord
    /// The distinct, sorted repository names this Feature's Cycle touches, from `feature_repository`
    /// — recorded at selection, never derived from `card` rows. The record of what the Feature was meant
    /// to touch: it never shrinks, and is not what the gate tests ancestry over (see
    /// ``pushedRepositories``).
    public let touchedRepositories: [String]
    /// N: the touched repositories minus those with a recorded No-Pushed-Branch Outcome
    /// (``JournalStore/pushedRepositories(featureID:)``) — the only repositories the gate tests ancestry
    /// over.
    public let pushedRepositories: [String]
}

/// What walking back from the most recent archived Feature found (roadmap P9.9; spec:
/// feature-authoring/select-the-next-feature, third story; risks.md Authoring Halt Ruling item 12,
/// OQ63): the first archived, unreleased Feature the gate must check, and every released Feature the
/// walk stepped past on the way there — more recent than the predecessor, archived, and released.
public struct PredecessorWalk: Equatable, Sendable {
    /// The predecessor to check ancestry against; nil when every archived Feature has been released,
    /// or there is no archived Feature at all (the first Night: the gate is open).
    public let predecessor: PredecessorFeature?
    /// Released Features the walk skipped, most recent first, so the Engine can record one
    /// `predecessorWalkSkippedReleasedFeature` event per Feature it passed over.
    public let skippedReleased: [FeatureRecord]
}

/// A Feature whose open Cycle has landed (roadmap P9.9, 1f): the in-flight Feature the gate observes
/// ancestry for alongside gating the predecessor. A branch freshly cut from mainline is trivially an
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
    /// Walks back from the most recent archived Feature (its Cycle archived, not the open Cycle),
    /// skipping every one already released, until it finds one that is not — the predecessor the gate
    /// checks ancestry against — or runs out.
    ///
    /// A Feature with no Cycle at all (an inconsistent Journal, never produced by this engine) is
    /// never returned: a Cycle's `feature_id` is what this joins on.
    public func predecessorFeature() throws -> PredecessorWalk {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feature.*, cycle.landed_at AS landed_at FROM feature
                JOIN cycle ON cycle.feature_id = feature.id
                WHERE cycle.archived_at IS NOT NULL
                ORDER BY feature.id DESC
                """
            )
            var skipped: [FeatureRecord] = []
            for row in rows {
                let feature = try Self.featureRecord(from: row)
                guard feature.abandonedAt == nil else {
                    skipped.append(feature)
                    continue
                }
                let repositories = try Self.touchedRepositories(db, featureID: feature.id)
                // N is the finalized landing record's pushed set. A Feature the Board completed before
                // its Cycle ever landed has no landing record, so nothing was pushed: N = 0, never the
                // touched list, whose branches were never pushed or recorded (triage-the-morning).
                let landedAt: String? = row["landed_at"]
                let pushed = try Self.closedFeaturePushedRepositories(db, feature: feature, landedAt: landedAt)
                return PredecessorWalk(
                    predecessor: PredecessorFeature(
                        feature: feature, touchedRepositories: repositories, pushedRepositories: pushed
                    ),
                    skippedReleased: skipped
                )
            }
            return PredecessorWalk(predecessor: nil, skippedReleased: skipped)
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
