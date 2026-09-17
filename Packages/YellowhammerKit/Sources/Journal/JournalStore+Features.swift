import Domain
import Foundation
import GRDB

/// A Feature Issue as the Journal holds it.
public struct FeatureRecord: Equatable, Sendable {
    public let id: Int64
    public let issueID: String
    public let state: String
    /// The Feature Branch name (`yh-<project>-<feature>`), recorded by the author Act. Nil until then.
    public let branch: FeatureBranch?
    public let createdAt: Date
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

    /// Records the Feature Branch name for `featureID`. A simple update: the author Act records this
    /// once, and tests set it up directly for the phases that read it before author writes it.
    public func recordFeatureBranch(featureID: Int64, branch: FeatureBranch) throws {
        try write { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM feature WHERE id = ?", arguments: [featureID]) != nil else {
                throw JournalError.featureUnknown(featureID: featureID)
            }
            try db.execute(
                sql: "UPDATE feature SET branch = ? WHERE id = ?",
                arguments: [branch.rawValue, featureID]
            )
        }
    }

    static func featureRecord(from row: Row) throws -> FeatureRecord {
        let id: Int64 = row["id"]
        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.featureUnknown(featureID: id) }
        let rawBranch: String? = row["branch"]
        return FeatureRecord(
            id: id,
            issueID: row["issue_id"],
            state: row["state"],
            branch: rawBranch.map { FeatureBranch(rawValue: $0) },
            createdAt: createdAt
        )
    }
}
