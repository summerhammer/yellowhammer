import Domain
import Foundation
import GRDB

// Small Journal reads the Night Summary (roadmap P12.1) needs and no earlier phase recorded: pull
// requests scoped to one Night, and a Feature's Cycle id. Everything else the Night Summary renders
// from comes from readers that already existed (`events(ofType:)`, `laneHoles(cycleID:)`,
// `inFlightCycleID()`, `inFlightLandedFeature()`, `card(id:)`, `attemptHistory(cardID:)`).

extension JournalStore {
    /// Every pull request recorded for `nightID`, ordered by repository — the Night Summary's
    /// `**Pull requests:**` section reads this rather than `pullRequests(featureID:)`, which is scoped
    /// to a Feature across every Night it touched.
    public func pullRequests(nightID: Int64) throws -> [PullRequestRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT feature_id, repository, url, night_id, run_id, opened_at
                FROM pull_request WHERE night_id = ? ORDER BY repository ASC
                """,
                arguments: [nightID]
            )
            return try rows.map { row -> PullRequestRecord in
                let featureID: Int64 = row["feature_id"]
                let openedAt = try JournalStore.date(row["opened_at"]) {
                    JournalError.pullRequestUnreadable(featureID: featureID)
                }
                let runIDText: String = row["run_id"]
                return PullRequestRecord(
                    featureID: featureID,
                    repository: row["repository"],
                    url: row["url"],
                    nightID: row["night_id"],
                    runID: RunID(rawValue: runIDText) ?? RunID(),
                    openedAt: openedAt
                )
            }
        }
    }
}
