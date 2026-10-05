import Domain
import Foundation
import GRDB

extension JournalStore {
    /// The Feature Branch Orca ADE reported for `featureID`'s `repository`, nil when the pair has no row
    /// or no branch recorded yet.
    public func featureBranch(featureID: Int64, repository: String) throws -> FeatureBranch? {
        try read { db in
            let raw = try String.fetchOne(
                db,
                sql: "SELECT branch FROM feature_repository WHERE feature_id = ? AND repository = ?",
                arguments: [featureID, repository]
            )
            return raw.map { FeatureBranch(rawValue: $0) }
        }
    }

    /// Every repository of `featureID` with a recorded Feature Branch. Released Features included.
    public func featureBranches(featureID: Int64) throws -> [String: FeatureBranch] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT repository, branch FROM feature_repository WHERE feature_id = ? AND branch IS NOT NULL",
                arguments: [featureID]
            )
            var branches: [String: FeatureBranch] = [:]
            for row in rows {
                let repository: String = row["repository"]
                let branch: String = row["branch"]
                branches[repository] = FeatureBranch(rawValue: branch)
            }
            return branches
        }
    }

    /// Records the Feature Branch Orca ADE reported for `featureID`'s `repository`: set once, a repeat of
    /// the same name is a no-op, a different name throws ``JournalError/featureBranchConflict(featureID:repository:recorded:reported:)``.
    /// One write transaction with no Act-lease revalidation: the standalone entry point (setup, tests).
    public func recordFeatureBranch(featureID: Int64, repository: String, branch: FeatureBranch) throws {
        try write { db in
            try Self.upsertFeatureBranch(db, featureID: featureID, repository: repository, branch: branch)
        }
    }

    /// The Feature Branch to use for `repository`: the recorded one, else the Feature's Worktree name.
    /// The fallback is deliberate — an unallocated lane's ref cannot exist, so ref probes fail as before.
    public func resolvedFeatureBranch(feature: FeatureRecord, repository: String) throws -> FeatureBranch? {
        let recorded = try featureBranch(featureID: feature.id, repository: repository)
        return Self.resolving(recorded: recorded, feature: feature)
    }

    /// ``resolvedFeatureBranch(feature:repository:)`` for each of `repositories` from one read. A
    /// repository that resolves to nil is omitted.
    public func resolvedFeatureBranches(
        feature: FeatureRecord, repositories: [String]
    ) throws -> [String: FeatureBranch] {
        let recorded = try featureBranches(featureID: feature.id)
        var branches: [String: FeatureBranch] = [:]
        for repository in repositories {
            branches[repository] = Self.resolving(recorded: recorded[repository], feature: feature)
        }
        return branches
    }

    private static func resolving(recorded: FeatureBranch?, feature: FeatureRecord) -> FeatureBranch? {
        recorded ?? feature.worktreeName.map { FeatureBranch(name: $0.rawValue) }
    }

    /// The single implementation of the rule behind every Feature Branch write. Also records the pair as
    /// a repository the Feature touches, so an allocated repository counts as touched.
    static func upsertFeatureBranch(
        _ db: Database, featureID: Int64, repository: String, branch: FeatureBranch
    ) throws {
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM feature WHERE id = ?", arguments: [featureID]) != nil else {
            throw JournalError.featureUnknown(featureID: featureID)
        }
        try db.execute(
            sql: "INSERT OR IGNORE INTO feature_repository (feature_id, repository) VALUES (?, ?)",
            arguments: [featureID, repository]
        )
        let recorded = try String.fetchOne(
            db,
            sql: "SELECT branch FROM feature_repository WHERE feature_id = ? AND repository = ?",
            arguments: [featureID, repository]
        )
        guard let recorded else {
            try db.execute(
                sql: "UPDATE feature_repository SET branch = ? WHERE feature_id = ? AND repository = ?",
                arguments: [branch.rawValue, featureID, repository]
            )
            return
        }
        guard recorded == branch.rawValue else {
            throw JournalError.featureBranchConflict(
                featureID: featureID, repository: repository, recorded: recorded, reported: branch.rawValue
            )
        }
    }
}
