import Domain
import Foundation
import GRDB

// The Unmerged Feature Stack U and the base each Feature is authored against (roadmap P23.1; spec:
// feature-authoring/select-the-next-feature `#unmerged-feature-stack` and `#effective-base`; multi-Feature
// Night ruling, point 4). Read from the Journal alone — the app and the engine both derive U from it, so
// nothing about U is kept in memory.

extension JournalStore {
    /// U, ordered F1…Fm by Feature id: every non-abandoned Feature whose Cycle is archived, whose N
    /// (``pushedRepositories(featureID:)``) is non-empty, and that has no Observed Merge in at least one
    /// repository of N. `closed_by` may be `verification` or `completion`; a Feature closed by merge has every
    /// repository of N merged, so it never qualifies. A Feature the Board completed before its Cycle ever
    /// landed has N = ∅ and is excluded; cancelling a Feature already in U changes nothing.
    public func unmergedFeatureStack() throws -> [UnmergedFeature] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feature.*, cycle.landed_at AS landed_at FROM feature
                JOIN cycle ON cycle.feature_id = feature.id
                WHERE cycle.archived_at IS NOT NULL AND feature.abandoned_at IS NULL
                ORDER BY feature.id ASC
                """
            )
            return try rows.compactMap { row in
                let feature = try Self.featureRecord(from: row)
                let landedAt: String? = row["landed_at"]
                let pushed = try Self.closedFeaturePushedRepositories(db, feature: feature, landedAt: landedAt)
                guard !pushed.isEmpty else { return nil }
                let merged = Set(try String.fetchAll(
                    db, sql: "SELECT repository FROM feature_landing WHERE feature_id = ?", arguments: [feature.id]
                ))
                let unmerged = pushed.filter { !merged.contains($0) }
                guard !unmerged.isEmpty else { return nil }
                return try Self.unmergedFeature(
                    db, feature: feature, pushed: pushed, unmerged: unmerged
                )
            }
        }
    }

    private static func unmergedFeature(
        _ db: Database, feature: FeatureRecord, pushed: [String], unmerged: [String]
    ) throws -> UnmergedFeature {
        var branches: [String: FeatureBranch] = [:]
        var landedCommits: [String: String] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT repository, branch, landed_commit FROM feature_repository WHERE feature_id = ?",
            arguments: [feature.id]
        ) {
            let repository: String = row["repository"]
            guard pushed.contains(repository) else { continue }
            if let branch: String = row["branch"] { branches[repository] = FeatureBranch(rawValue: branch) }
            if let commit: String = row["landed_commit"] { landedCommits[repository] = commit }
        }
        return UnmergedFeature(
            feature: feature,
            touchedRepositories: try touchedRepositories(db, featureID: feature.id),
            pushedRepositories: pushed,
            branches: branches,
            landedCommits: landedCommits,
            mergedRepositories: pushed.filter { !unmerged.contains($0) },
            unmergedRepositories: unmerged
        )
    }

    /// `effective_base(R)` for `repository`: the most recent (highest Feature id) Feature in U that pushed
    /// there and has no Observed Merge there, or nil when the base is mainline. `excludingFeatureID` skips
    /// one Feature — the one being landed or authored, which is never its own base.
    public func effectiveBase(repository: String, excludingFeatureID: Int64? = nil) throws -> EffectiveBase? {
        for member in try unmergedFeatureStack().reversed() {
            guard member.feature.id != excludingFeatureID, member.unmergedRepositories.contains(repository) else {
                continue
            }
            // A pushed repository always has a recorded branch; the Worktree name is the same fallback
            // `resolvedFeatureBranch` uses for an unallocated lane.
            guard let branch = member.branches[repository]
                ?? member.feature.worktreeName.map({ FeatureBranch(rawValue: $0.rawValue) })
            else { continue }
            return EffectiveBase(
                featureID: member.feature.id, featureIssueID: member.feature.issueID, branch: branch,
                landedCommit: member.landedCommits[repository]
            )
        }
        return nil
    }

    /// Records the bases `featureID` was authored against, one `feature_base` row per repository. Idempotent:
    /// a repeated call replaces the row for the same repository.
    public func recordFeatureBases(featureID: Int64, bases: [FeatureBaseRecord]) throws {
        try write { db in try Self.recordFeatureBases(db, featureID: featureID, bases: bases) }
    }

    /// ``recordFeatureBases(featureID:bases:)`` inside a caller's transaction (`finaliseAuthoring`).
    static func recordFeatureBases(_ db: Database, featureID: Int64, bases: [FeatureBaseRecord]) throws {
        for base in bases {
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO feature_base
                    (feature_id, repository, base_ref, base_commit, stacked_on_feature_id)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [featureID, base.repository, base.baseRef, base.baseCommit, base.stackedOnFeatureID]
            )
        }
    }

    /// The bases recorded for `featureID`, sorted by repository; empty when none were recorded.
    public func featureBases(featureID: Int64) throws -> [FeatureBaseRecord] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT repository, base_ref, base_commit, stacked_on_feature_id FROM feature_base
                WHERE feature_id = ? ORDER BY repository ASC
                """,
                arguments: [featureID]
            ).map { row in
                FeatureBaseRecord(
                    repository: row["repository"], baseRef: row["base_ref"], baseCommit: row["base_commit"],
                    stackedOnFeatureID: row["stacked_on_feature_id"]
                )
            }
        }
    }

    /// Whether an unarchived Cycle's Feature recorded `baseRef` as its base in `repository` (spec:
    /// feature-authoring/select-the-next-feature, `#tested-tip`): a landed pin it names is kept past its own
    /// Feature's Observed Merge until that Cycle archives, because a lane not yet allocated is cut from it.
    public func isBaseOfOpenCycle(repository: String, baseRef: String) throws -> Bool {
        try read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM feature_base JOIN cycle ON cycle.feature_id = feature_base.feature_id
                    WHERE cycle.archived_at IS NULL AND feature_base.repository = ? AND feature_base.base_ref = ?
                )
                """,
                arguments: [repository, baseRef]
            ) ?? false
        }
    }
}
