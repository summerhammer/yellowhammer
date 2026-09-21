import Domain
import Foundation
import GRDB

// Records a Repo Lane's opened pull request (roadmap P10.4), once per (feature, repository): first
// write wins, and the seam above this never updates, duplicates or reopens.

/// One recorded pull request.
public struct PullRequestRecord: Equatable, Sendable {
    public let featureID: Int64
    public let repository: String
    /// Nil when GitHub reported `.alreadyOpen` — this Port never reads, so there is no URL to record.
    public let url: String?
    public let nightID: Int64
    public let runID: RunID
    public let openedAt: Date
}

extension JournalStore {
    /// Records `featureID`'s pull request for `repository`, first write wins. Returns whether this
    /// call inserted a new row — false means a pull request was already recorded, and the caller must
    /// not open another.
    @discardableResult
    public func recordPullRequest(
        featureID: Int64, repository: String, url: String?, nightID: Int64, runID: RunID, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO pull_request (feature_id, repository, url, night_id, run_id, opened_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [featureID, repository, url, nightID, runID.rawValue, timestamp]
            )
            return db.changesCount == 1
        }
    }

    /// Every pull request recorded for `featureID`, keyed by repository.
    public func pullRequests(featureID: Int64) throws -> [String: PullRequestRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feature_id, repository, url, night_id, run_id, opened_at
                FROM pull_request WHERE feature_id = ?
                """,
                arguments: [featureID]
            )
            var result: [String: PullRequestRecord] = [:]
            for row in rows {
                let repository: String = row["repository"]
                let featureID: Int64 = row["feature_id"]
                let openedAt = try JournalStore.date(row["opened_at"]) {
                    JournalError.pullRequestUnreadable(featureID: featureID)
                }
                let runIDText: String = row["run_id"]
                result[repository] = PullRequestRecord(
                    featureID: featureID,
                    repository: repository,
                    url: row["url"],
                    nightID: row["night_id"],
                    runID: RunID(rawValue: runIDText) ?? RunID(),
                    openedAt: openedAt
                )
            }
            return result
        }
    }

    /// The pull request recorded for `featureID`'s `repository`, if any.
    public func pullRequest(featureID: Int64, repository: String) throws -> PullRequestRecord? {
        try pullRequests(featureID: featureID)[repository]
    }
}
