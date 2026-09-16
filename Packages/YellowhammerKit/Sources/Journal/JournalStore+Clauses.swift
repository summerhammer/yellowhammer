import Domain
import Foundation
import GRDB

/// A clause row from the `clause` table.
public struct ClauseRecord: Equatable, Sendable {
    public let cid: String
    public let issueID: String
    public let level: String
    public let text: String
    public let locationID: String
    public let provenance: String
    public let citationProvenance: String
    public let invalidated: Bool
    public let deleted: Bool
    public let createdAt: Date
}

extension JournalStore {
    /// Clauses of an issue, ordered by created_at ASC, cid ASC. Excludes deleted rows.
    public func clauses(issueID: String) throws -> [ClauseRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM clause
                WHERE issue_id = ? AND deleted = 0
                ORDER BY created_at ASC, cid ASC
                """,
                arguments: [issueID]
            )
            return try rows.map { row in
                try Self.clauseRecord(from: row)
            }
        }
    }

    /// How many Cards of a Cycle are in a repository, in authored order. Cancelled Cards still count.
    public func repoLaneLength(cycleID: Int64, repository: String) throws -> Int {
        try read { db in
            guard let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM card WHERE cycle_id = ? AND repository = ?",
                arguments: [cycleID, repository]
            ) else {
                return 0
            }
            return count
        }
    }

    // MARK: - Private Helpers

    private static func clauseRecord(from row: Row) throws -> ClauseRecord {
        let cid: String = row["cid"]
        let issueID: String = row["issue_id"]
        let onError = { JournalError.clauseUnreadable(issueID: issueID, cid: cid) }

        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText, onError: onError)

        return ClauseRecord(
            cid: cid,
            issueID: issueID,
            level: row["level"],
            text: row["text"],
            locationID: row["location_id"],
            provenance: row["provenance"],
            citationProvenance: row["citation_provenance"],
            invalidated: ((row["invalidated"] as Int?) ?? 0) != 0,
            deleted: ((row["deleted"] as Int?) ?? 0) != 0,
            createdAt: createdAt
        )
    }
}
