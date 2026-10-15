import Domain
import Foundation
import GRDB

// The Observed Release gate's durable state (feature-authoring/select-the-next-feature, `#release-gate`):
// the release-shaped tag of a producer Repo first observed to contain a Feature's work there, and the
// Feature the gate must check for a producer. Journal-only; Yellowhammer only reads tags.

/// The release-shaped tag first observed to contain a Feature's work in a producer Repo.
public struct ObservedRelease: Equatable, Sendable {
    public let tagName: String
    /// The commit the tag names (peeled, for an annotated tag).
    public let tagCommit: String

    public init(tagName: String, tagCommit: String) {
        self.tagName = tagName
        self.tagCommit = tagCommit
    }
}

extension JournalStore {
    /// Records the Observed Release of `featureID` in `repository`, first-observation wins: a later pass
    /// never overwrites the tag a first pass recorded. Returns whether this call inserted a new row.
    @discardableResult
    public func recordRelease(
        featureID: Int64, repository: String, tagName: String, tagCommit: String, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO feature_release (feature_id, repository, tag_name, tag_commit, observed_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [featureID, repository, tagName, tagCommit, timestamp]
            )
            return db.changesCount == 1
        }
    }

    /// Every Observed Release recorded for `featureID`, keyed by repository name.
    public func releases(featureID: Int64) throws -> [String: ObservedRelease] {
        try read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT repository, tag_name, tag_commit FROM feature_release WHERE feature_id = ?",
                arguments: [featureID]
            )
            var result: [String: ObservedRelease] = [:]
            for row in rows {
                let repository: String = row["repository"]
                result[repository] = ObservedRelease(tagName: row["tag_name"], tagCommit: row["tag_commit"])
            }
            return result
        }
    }

    /// This Project's most recent Feature whose Cycle is archived, that is not abandoned, and that pushed
    /// in `repository` (the touched repositories minus those with a No-Pushed-Branch Outcome): the Feature
    /// whose release the gate waits for when `repository` is read by tag. Nil when none.
    public func latestFeaturePushed(in repository: String) throws -> FeatureRecord? {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feature.* FROM feature
                JOIN cycle ON cycle.feature_id = feature.id
                WHERE cycle.archived_at IS NOT NULL AND feature.abandoned_at IS NULL
                ORDER BY feature.id DESC
                """
            )
            for row in rows {
                let feature = try Self.featureRecord(from: row)
                if try Self.pushedRepositories(db, featureID: feature.id).contains(repository) {
                    return feature
                }
            }
            return nil
        }
    }
}
