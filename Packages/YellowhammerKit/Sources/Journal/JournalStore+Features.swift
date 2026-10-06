import Domain
import Foundation
import GRDB

/// Which route closed a Feature (roadmap P10.7/P10.8; spec: verification/archive-the-cycle-on-a-
/// verified-feature): every Definition of Done clause verified met, or a Partial Landing the Operator
/// merged (P10.8, not yet built).
public enum FeatureClosure: String, Equatable, Sendable {
    case verification
    case merge
}

/// A Feature Issue as the Journal holds it.
public struct FeatureRecord: Equatable, Sendable {
    public let id: Int64
    public let issueID: String
    /// The Feature issue's human-readable identifier (e.g. `ARC-10`), recorded for display.
    public internal(set) var issueIDForDisplay: String?
    public let state: String
    /// The Worktree name (`yh-<project>-<feature>`) requested from Orca ADE, recorded by the author Act.
    /// Nil until then. The Feature Branch itself is per repository (``JournalStore/featureBranch(featureID:repository:)``).
    public let worktreeName: WorktreeName?
    public let createdAt: Date
    /// When this Feature was abandoned (P10.9; OQ128), nil until then. An abandoned Feature
    /// satisfies the predecessor gate for no repository and is never returned as the predecessor to
    /// check ancestry against — the walk moves past it (roadmap P9.9).
    public let abandonedAt: Date?
    /// Which route closed this Feature, nil until its Cycle is archived (roadmap P10.7).
    public let closedBy: FeatureClosure?
    /// The Feature issue's Linear `identifier` (e.g. `YH-142`), recorded by the Delta Read; nil until
    /// then (issue #230).
    public internal(set) var issueKey: String?
    /// The Feature issue's board URL as Linear gave it, recorded with ``issueKey``; nil until then.
    public internal(set) var issueURL: String?

    public init(
        id: Int64,
        issueID: String,
        issueIDForDisplay: String? = nil,
        state: String,
        worktreeName: WorktreeName?,
        createdAt: Date,
        abandonedAt: Date?,
        closedBy: FeatureClosure?,
        issueKey: String? = nil,
        issueURL: String? = nil
    ) {
        self.id = id
        self.issueID = issueID
        self.issueIDForDisplay = issueIDForDisplay
        self.state = state
        self.worktreeName = worktreeName
        self.createdAt = createdAt
        self.abandonedAt = abandonedAt
        self.closedBy = closedBy
        self.issueKey = issueKey
        self.issueURL = issueURL
    }

    public init(
        id: Int64,
        issueID: String,
        state: String,
        worktreeName: WorktreeName?,
        createdAt: Date,
        abandonedAt: Date?,
        closedBy: FeatureClosure?,
        issueKey: String? = nil,
        issueURL: String? = nil
    ) {
        self.init(
            id: id,
            issueID: issueID,
            issueIDForDisplay: nil,
            state: state,
            worktreeName: worktreeName,
            createdAt: createdAt,
            abandonedAt: abandonedAt,
            closedBy: closedBy,
            issueKey: issueKey,
            issueURL: issueURL
        )
    }
}

extension JournalStore {
    /// The Feature currently in flight and its open Cycle's id, nil when no Cycle is open
    /// (``inFlightCycleID()``).
    public func inFlightFeature() throws -> (feature: FeatureRecord, cycleID: Int64)? {
        guard let cycleID = try inFlightCycleID() else { return nil }
        return try read { db in
            guard
                let cycleRow = try Row.fetchOne(
                    db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID]
                )
            else {
                throw JournalError.cycleUnknown(cycleID: cycleID)
            }
            let featureID: Int64 = cycleRow["feature_id"]
            guard
                let featureRow = try Row.fetchOne(db, sql: "SELECT * FROM feature WHERE id = ?", arguments: [featureID])
            else {
                throw JournalError.featureUnknown(featureID: featureID)
            }
            return (try Self.featureRecord(from: featureRow), cycleID)
        }
    }

    /// Every Card of `cycleID`, ordered the way a build Act derives Repo Lanes: by repository, then by
    /// the order the Cards were authored in.
    public func cards(cycleID: Int64) throws -> [CardRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM card WHERE cycle_id = ? ORDER BY repository ASC, authored_order ASC",
                arguments: [cycleID]
            )
            return try rows.map { try Self.cardRecord(from: $0) }
        }
    }

    /// The Feature named `issueID`, nil when the Journal has no `feature` row for it — a Feature Issue
    /// still Waiting on You under a Refusal or Authoring Halt has none yet (roadmap P12.3).
    public func feature(issueID: String) throws -> FeatureRecord? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM feature WHERE issue_id = ?", arguments: [issueID])
            else {
                return nil
            }
            return try Self.featureRecord(from: row)
        }
    }

    /// The Feature with this id, nil when the Journal has no `feature` row for it.
    public func feature(id: Int64) throws -> FeatureRecord? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM feature WHERE id = ?", arguments: [id])
            else {
                return nil
            }
            return try Self.featureRecord(from: row)
        }
    }

    /// Records the Worktree name for `featureID`. A simple update: the author Act records this
    /// once, and tests set it up directly for the phases that read it before author writes it.
    public func recordWorktreeName(featureID: Int64, worktreeName: WorktreeName) throws {
        try write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM feature WHERE id = ?", arguments: [featureID]) != nil else {
                throw JournalError.featureUnknown(featureID: featureID)
            }
            try db.execute(
                sql: "UPDATE feature SET worktree_name = ? WHERE id = ?",
                arguments: [worktreeName.rawValue, featureID]
            )
        }
    }

    static func featureRecord(from row: Row) throws -> FeatureRecord {
        let id: Int64 = row["id"]
        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.featureUnknown(featureID: id) }
        let rawWorktreeName: String? = row["worktree_name"]
        let rawAbandonedAt: String? = row["abandoned_at"]
        let rawClosedBy: String? = row["closed_by"]
        return FeatureRecord(
            id: id,
            issueID: row["issue_id"],
            issueIDForDisplay: row["issue_id_for_display"] ?? row["issue_key"],
            state: row["state"],
            worktreeName: rawWorktreeName.map { WorktreeName(rawValue: $0) },
            createdAt: createdAt,
            abandonedAt: try rawAbandonedAt.map { try Self.date($0) { JournalError.featureUnknown(featureID: id) } },
            closedBy: rawClosedBy.flatMap { FeatureClosure(rawValue: $0) },
            issueKey: row["issue_key"],
            issueURL: row["issue_url"]
        )
    }
}
