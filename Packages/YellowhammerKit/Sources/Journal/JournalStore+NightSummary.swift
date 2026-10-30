import Domain
import Foundation
import GRDB

// Small Journal reads the Night Summary (roadmap P12.1) needs and no earlier phase recorded: pull
// requests scoped to one Night, and a Feature's Cycle id. Everything else the Night Summary renders
// from comes from readers that already existed (`events(ofType:)`, `laneHoles(cycleID:)`,
// `inFlightCycleID()`, `inFlightLandedFeature()`, `card(id:)`, `attemptHistory(cardID:)`).

extension JournalStore {
    /// Distinct Feature Cards still requiring attention after an Authoring Halt. Expiry changes the
    /// Card from Waiting on You to Blocked; only clearing the halt removes its decision. A halt with
    /// no recorded board issue does not represent a Card, and historical cleared rows never count.
    public func unresolvedAuthoringHaltCardCount() throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(DISTINCT issue_id) FROM authoring_halt
                WHERE state IN ('open', 'expired') AND issue_id IS NOT NULL
                """
            ) ?? 0
        }
    }

    /// Every pull request recorded for `nightID`, ordered by repository — the Night Summary's
    /// `**Pull requests:**` section reads this rather than `pullRequests(featureID:)`, which is scoped
    /// to a Feature across every Night it touched.
    public func pullRequests(nightID: Int64) throws -> [PullRequestRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT \(Self.pullRequestColumns) FROM pull_request WHERE night_id = ? ORDER BY repository ASC",
                arguments: [nightID]
            )
            return try rows.map(Self.pullRequestRecord(from:))
        }
    }
}
