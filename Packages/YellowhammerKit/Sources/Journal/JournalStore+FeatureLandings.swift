import Domain
import Foundation
import GRDB

// The predecessor gate's own durable state (roadmap P9.9): the repositories a Feature touches,
// recorded at selection time (never derived from Cards — a Card's repository row can disappear long
// after the Feature that touched it is a predecessor), the landings observed for it, and whether it
// has been released. `JournalStore+Predecessor.swift` stays the small read the gate calls to find the
// Feature to check; this file holds the rest.

extension JournalStore {
    /// The distinct, sorted repository names `featureID`'s Cycle touches, as recorded at selection
    /// time in `feature_repository` — never derived from `card` rows, which can lose a repository
    /// (a Card cancelled or adopted elsewhere) long after the Feature that touched it stops being
    /// in flight.
    public func touchedRepositories(featureID: Int64) throws -> [String] {
        try read { db in try Self.touchedRepositories(db, featureID: featureID) }
    }

    /// Records that `repository`'s mainline has merged `featureID`'s Feature Branch, first-observation
    /// wins: a later pass that finds the same repository still merged never overwrites the commit a
    /// first pass recorded. Returns whether this call inserted a new row.
    @discardableResult
    public func recordLanding(
        featureID: Int64, repository: String, mainlineCommit: String, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO feature_landing (feature_id, repository, mainline_commit, observed_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [featureID, repository, mainlineCommit, timestamp]
            )
            return db.changesCount == 1
        }
    }

    /// Every repository `featureID` has a recorded landing for, keyed by repository name, and the
    /// mainline commit first observed to contain it.
    public func landings(featureID: Int64) throws -> [String: String] {
        try read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT repository, mainline_commit FROM feature_landing WHERE feature_id = ?",
                arguments: [featureID]
            )
            var result: [String: String] = [:]
            for row in rows {
                let repository: String = row["repository"]
                let mainlineCommit: String = row["mainline_commit"]
                result[repository] = mainlineCommit
            }
            return result
        }
    }

    /// Marks `featureID` released (P10.9, not yet built): once set, this Feature satisfies the
    /// predecessor gate for no repository and is never returned as the predecessor to check — the walk
    /// moves past it to the Feature before it.
    public func markFeatureReleased(featureID: Int64, now: Date = Date()) throws {
        try write { db in
            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            try db.execute(sql: "UPDATE feature SET released_at = ? WHERE id = ?", arguments: [timestamp, featureID])
            guard db.changesCount == 1 else { throw JournalError.featureUnknown(featureID: featureID) }
        }
    }

    /// Records the repositories a newly authored Feature's Cycle touches, from the plan's own
    /// validated selection — never derived from Cards. Called inside ``finaliseAuthoring(_:runID:act:nightID:now:)``'s
    /// own write transaction, so a Feature never exists without its touched repositories recorded.
    static func insertFeatureRepositories(_ db: Database, featureID: Int64, repositories: [String]) throws {
        for repository in repositories {
            try db.execute(
                sql: "INSERT OR IGNORE INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                arguments: [featureID, repository]
            )
        }
    }
}
