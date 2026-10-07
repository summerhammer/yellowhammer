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
    public let invalidatedCause: String?
    public let deleted: Bool
    public let createdAt: Date

    public init(
        cid: String,
        issueID: String,
        level: String,
        text: String,
        locationID: String,
        provenance: String,
        citationProvenance: String,
        invalidated: Bool,
        invalidatedCause: String? = nil,
        deleted: Bool,
        createdAt: Date
    ) {
        self.cid = cid
        self.issueID = issueID
        self.level = level
        self.text = text
        self.locationID = locationID
        self.provenance = provenance
        self.citationProvenance = citationProvenance
        self.invalidated = invalidated
        self.invalidatedCause = invalidatedCause
        self.deleted = deleted
        self.createdAt = createdAt
    }
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

    /// The next clause id for an issue: `c<N>` where N is one more than the highest numeric suffix over
    /// every clause row for the issue, including deleted ones. `c1` when the issue has none.
    public func nextClauseID(issueID: String) throws -> String {
        try read { db in
            let cids = try String.fetchAll(
                db, sql: "SELECT cid FROM clause WHERE issue_id = ?", arguments: [issueID]
            )
            let maxSuffix = cids.compactMap { cid -> Int? in
                guard cid.hasPrefix("c") else { return nil }
                return Int(cid.dropFirst())
            }.max() ?? 0
            return "c\(maxSuffix + 1)"
        }
    }

    /// Everything a new clause row needs, bundled so `insertClause` stays under the parameter-count limit.
    public struct NewClause: Sendable {
        public let cid: String
        public let issueID: String
        public let level: String
        public let text: String
        public let locationID: String
        public let provenance: String
        public let citationProvenance: String

        public init(
            cid: String, issueID: String, level: String, text: String, locationID: String,
            provenance: String, citationProvenance: String
        ) {
            self.cid = cid
            self.issueID = issueID
            self.level = level
            self.text = text
            self.locationID = locationID
            self.provenance = provenance
            self.citationProvenance = citationProvenance
        }
    }

    /// Inserts a new clause row.
    @discardableResult
    public func insertClause(_ clause: NewClause, now: Date = Date()) throws -> ClauseRecord {
        let stored = JournalStore.timestamp(JournalStore.stored(now))
        return try write { db in
            try Self.insertClauseRow(db, clause, timestamp: stored)
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM clause WHERE issue_id = ? AND cid = ?", arguments: [clause.issueID, clause.cid]
            ) else {
                throw JournalError.clauseUnreadable(issueID: clause.issueID, cid: clause.cid)
            }
            return try Self.clauseRecord(from: row)
        }
    }

    /// The SQL a clause row insert shares with every writer that inserts one inside an already-open
    /// transaction (``finaliseAuthoring``, roadmap P9.5) rather than opening its own.
    static func insertClauseRow(_ db: Database, _ clause: NewClause, timestamp: String) throws {
        try db.execute(
            sql: """
            INSERT INTO clause (
                cid, issue_id, level, text, location_id, provenance, citation_provenance, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                clause.cid, clause.issueID, clause.level, clause.text, clause.locationID,
                clause.provenance, clause.citationProvenance, timestamp
            ]
        )
    }

    /// Marks a tagged clause invalidated: its identity (`cid`) is preserved, but its text or citation
    /// changed on the board. `cause` is `text_edited` or `citation_edited`.
    public func invalidateClause(issueID: String, cid: String, cause: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE clause SET invalidated = 1, invalidated_cause = ? WHERE issue_id = ? AND cid = ?",
                arguments: [cause, issueID, cid]
            )
        }
    }

    /// Updates a clause's citation (`location_id`) and marks its citation Author-supplied — an Operator
    /// edited the citation directly on the board.
    public func updateClauseCitation(issueID: String, cid: String, locationID: String) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE clause SET location_id = ?, citation_provenance = 'Author-supplied'
                WHERE issue_id = ? AND cid = ?
                """,
                arguments: [locationID, issueID, cid]
            )
        }
    }

    /// Marks a clause deleted: it is no longer on the board, but its history is preserved.
    public func markClauseDeleted(issueID: String, cid: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE clause SET deleted = 1 WHERE issue_id = ? AND cid = ?",
                arguments: [issueID, cid]
            )
        }
    }

    /// How many Cards of a Cycle are in a repository, in authored order. Shelved Cards still count.
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
            invalidatedCause: row["invalidated_cause"],
            deleted: ((row["deleted"] as Int?) ?? 0) != 0,
            createdAt: createdAt
        )
    }
}

extension JournalStore {
    /// How many consecutive Divergences this Card has had, reset to 0 by any clean provenance pass.
    public func consecutiveDivergences(cardID: Int64) throws -> Int {
        try read { db in
            (try Int.fetchOne(db, sql: "SELECT consecutive_divergences FROM card WHERE id = ?", arguments: [cardID]))
                ?? 0
        }
    }

    /// Increments the Card's consecutive-Divergence counter and returns the new value.
    @discardableResult
    public func incrementConsecutiveDivergences(cardID: Int64) throws -> Int {
        try write { db in
            try db.execute(
                sql: "UPDATE card SET consecutive_divergences = consecutive_divergences + 1 WHERE id = ?",
                arguments: [cardID]
            )
            guard let value = try Int.fetchOne(
                db, sql: "SELECT consecutive_divergences FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            return value
        }
    }

    /// Resets the Card's consecutive-Divergence counter to 0, on a clean provenance pass.
    public func resetConsecutiveDivergences(cardID: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE card SET consecutive_divergences = 0 WHERE id = ?", arguments: [cardID]
            )
        }
    }
}
