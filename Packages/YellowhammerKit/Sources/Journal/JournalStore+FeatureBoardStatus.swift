import Domain
import Foundation
import GRDB

extension JournalMigrations {
    static func createFeatureBoardStatusTable(_ db: Database) throws {
        try db.create(table: "feature_board_status") { table in
            table.column("issue_id", .text).primaryKey()
            table.column("updated_at", .text).notNull()
            table.column("payload", .text).notNull()
        }
    }
}

extension JournalStore {
    /// Latest native Feature state, retained for the lifetime of its Journal identity, including after
    /// Cycle archival. The payload preserves state id, name and translated category with its revision.
    public func featureBoardObservation(issueID: String) throws -> BoardObject? {
        try read { try Self.featureBoardObservation($0, issueID: issueID) }
    }

    static func featureBoardObservation(_ db: Database, issueID: String) throws -> BoardObject? {
        guard let payload = try String.fetchOne(
            db, sql: "SELECT payload FROM feature_board_status WHERE issue_id = ?", arguments: [issueID]
        ) else { return nil }
        return try JSONDecoder().decode(BoardObject.self, from: Data(payload.utf8))
    }

    /// Called in the same fenced transaction as the sync checkpoint, before its cursors advance.
    /// An equal revision is immutable: overlap or replay cannot replace its workflow evidence.
    static func storeFeatureBoardObservations(_ db: Database, _ observations: [BoardIssueObservation]) throws {
        for observation in observations {
            guard try Bool.fetchOne(
                db, sql: "SELECT EXISTS(SELECT 1 FROM feature WHERE issue_id = ?)", arguments: [observation.issueID]
            ) == true else { continue }
            guard let object = try? JSONDecoder().decode(BoardObject.self, from: Data(observation.payload.utf8)),
                  object.id.rawValue == observation.issueID, object.updatedAt == observation.updatedAt else { continue }
            if let held = try Self.featureBoardObservation(db, issueID: observation.issueID),
               held.updatedAt >= object.updatedAt { continue }
            try db.execute(sql: """
                INSERT INTO feature_board_status (issue_id, updated_at, payload) VALUES (?, ?, ?)
                ON CONFLICT (issue_id) DO UPDATE SET
                    updated_at = excluded.updated_at, payload = excluded.payload
                """, arguments: [observation.issueID, Self.syncTimestamp(observation.updatedAt), observation.payload])
        }
    }

    /// Tracked Feature identities with durable observations, including closed Cycles. Maintenance uses
    /// these to recompute status-only changes and removal of an annotation after leaving U.
    public func observedFeaturesWithCycles() throws -> [(FeatureRecord, Int64)] {
        try read { db in
            try Row.fetchAll(db, sql: """
                SELECT feature.*, cycle.id AS cycle_id FROM feature
                JOIN feature_board_status ON feature_board_status.issue_id = feature.issue_id
                JOIN cycle ON cycle.feature_id = feature.id ORDER BY feature.id
                """).map { (try Self.featureRecord(from: $0), $0["cycle_id"]) }
        }
    }
}
