import Domain
import Foundation
import GRDB

// Records a Repo Lane's opened pull request (roadmap P10.4), once per (feature, repository): first
// write wins, and the seam above this never updates, duplicates or reopens. What the pull request read
// observes (feature-authoring/select-the-next-feature `#pull-request-read`, OQ190 items 14 and 16) is kept on
// the same row: overwritten by each successful read, never by anything else.

/// One recorded pull request, with its last observed state.
public struct PullRequestRecord: Equatable, Sendable {
    public let featureID: Int64
    public let repository: String
    /// Nil when GitHub reported `.alreadyOpen`: its refusal names no URL. The predecessor gate then finds the pull
    /// request by its head branch (OQ190 item 27), and the first read that finds it fills this in.
    public let url: String?
    public let nightID: Int64
    public let runID: RunID
    public let openedAt: Date
    /// The pull request's number, from the latest successful read. Nil until one.
    public let number: Int?
    /// The last observed state: `open`, `merged` or `closed without merge`. Nil when no read has succeeded yet. A
    /// failed read leaves it, and ``observedAt``, as they were. Never changes a recorded Observed Merge.
    public let observedState: ObservedPullRequestState?
    /// When ``observedState`` was observed.
    public let observedAt: Date?
    /// The pull request's head commit, as last observed.
    public let headCommit: String?
    /// The commit the pull request merged into its base branch; nil unless ``observedState`` is merged.
    public let mergeCommit: String?
    /// The branch the pull request targets, as last observed.
    public let baseBranch: String?

    public init(
        featureID: Int64, repository: String, url: String?, nightID: Int64, runID: RunID, openedAt: Date,
        number: Int? = nil, observedState: ObservedPullRequestState? = nil, observedAt: Date? = nil,
        headCommit: String? = nil, mergeCommit: String? = nil, baseBranch: String? = nil
    ) {
        self.featureID = featureID
        self.repository = repository
        self.url = url
        self.nightID = nightID
        self.runID = runID
        self.openedAt = openedAt
        self.number = number
        self.observedState = observedState
        self.observedAt = observedAt
        self.headCommit = headCommit
        self.mergeCommit = mergeCommit
        self.baseBranch = baseBranch
    }
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

    /// Records what a successful pull request read observed for `featureID`'s pull request in `repository`
    /// (`#pull-request-read`, "What it records"): its state and `now` as when it was observed, its number, its
    /// head and merge commits and its base branch, overwriting the previous observation. Where the land Act
    /// recorded no URL, the read's URL fills it in; a recorded URL is never replaced. Revalidates `runID`'s Act
    /// Lease in the same transaction. Updates only: with no recorded pull request it writes nothing and returns
    /// false, because a pull request the land Act did not record is not one Yellowhammer opened.
    @discardableResult
    public func recordObservedPullRequest(
        featureID: Int64, repository: String, observed: ObservedPullRequest, runID: RunID, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            try db.execute(
                sql: """
                UPDATE pull_request SET
                    observed_state = ?, observed_at = ?, number = ?, head_commit = ?, merge_commit = ?,
                    base_branch = ?, url = COALESCE(url, ?)
                WHERE feature_id = ? AND repository = ?
                """,
                arguments: [
                    observed.state.rawValue, JournalStore.timestamp(JournalStore.stored(now)), observed.number,
                    observed.headCommit, observed.mergeCommit, observed.baseBranch, observed.url,
                    featureID, repository
                ]
            )
            return db.changesCount == 1
        }
    }

    /// Every pull request recorded for `featureID`, keyed by repository.
    public func pullRequests(featureID: Int64) throws -> [String: PullRequestRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(Self.pullRequestColumns) FROM pull_request WHERE feature_id = ?",
                arguments: [featureID]
            )
            var result: [String: PullRequestRecord] = [:]
            for row in rows {
                let record = try Self.pullRequestRecord(from: row)
                result[record.repository] = record
            }
            return result
        }
    }

    /// The pull request recorded for `featureID`'s `repository`, if any.
    public func pullRequest(featureID: Int64, repository: String) throws -> PullRequestRecord? {
        try pullRequests(featureID: featureID)[repository]
    }

    /// The `pull_request` columns ``pullRequestRecord(from:)`` decodes.
    static let pullRequestColumns = """
        feature_id, repository, url, night_id, run_id, opened_at, number, observed_state, observed_at, \
        head_commit, merge_commit, base_branch
        """

    /// Decodes one `pull_request` row selected with ``pullRequestColumns``.
    static func pullRequestRecord(from row: Row) throws -> PullRequestRecord {
        let featureID: Int64 = row["feature_id"]
        let openedAt = try date(row["opened_at"]) { JournalError.pullRequestUnreadable(featureID: featureID) }
        let observedAtText: String? = row["observed_at"]
        let observedAt = try observedAtText.map { text in
            try date(text) { JournalError.pullRequestUnreadable(featureID: featureID) }
        }
        let stateText: String? = row["observed_state"]
        let observedState = try stateText.map { text in
            guard let state = ObservedPullRequestState(rawValue: text) else {
                throw JournalError.pullRequestUnreadable(featureID: featureID)
            }
            return state
        }
        let runIDText: String = row["run_id"]
        return PullRequestRecord(
            featureID: featureID, repository: row["repository"], url: row["url"], nightID: row["night_id"],
            runID: RunID(rawValue: runIDText) ?? RunID(), openedAt: openedAt, number: row["number"],
            observedState: observedState, observedAt: observedAt, headCommit: row["head_commit"],
            mergeCommit: row["merge_commit"], baseBranch: row["base_branch"]
        )
    }
}
