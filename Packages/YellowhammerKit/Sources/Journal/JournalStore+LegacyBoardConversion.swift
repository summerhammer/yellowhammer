import Domain
import Foundation
import GRDB

/// What kind of legacy conversion a ``LegacyBoardConversion`` row records.
public enum LegacyConversionKind: String, Sendable {
    /// A Feature Card in `Kept in Flight` or `Abandoned`, moved to a native state.
    case settle
    /// A Work Card's legacy `Override` label, converted to the `Card override:` field.
    case override
    /// The migration as a whole, keyed by ``LegacyBoardConversion/projectKey``.
    case project
}

/// Where one conversion stands.
public enum LegacyConversionStatus: String, Sendable {
    case planned, converted, conflict, complete
}

/// One row of the legacy Board migration's progress, as the Journal holds it.
public struct LegacyBoardConversion: Equatable, Sendable {
    /// The issue id the `project` row is keyed by: not an issue, so it can never collide with one.
    public static let projectKey = "*"

    public let issueID: String
    public let kind: LegacyConversionKind
    public let status: LegacyConversionStatus
    public let detail: String?
    public let version: Int
}

extension JournalStore {
    /// The conversion row for (`issueID`, `kind`), or nil when the migration has not touched it.
    public func legacyConversion(issueID: String, kind: LegacyConversionKind) throws -> LegacyBoardConversion? {
        try read { db in try Self.legacyConversion(db, issueID: issueID, kind: kind) }
    }

    static func legacyConversion(
        _ db: Database, issueID: String, kind: LegacyConversionKind
    ) throws -> LegacyBoardConversion? {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT * FROM legacy_board_conversion WHERE issue_id = ? AND kind = ?",
            arguments: [issueID, kind.rawValue]
        ) else { return nil }
        return LegacyBoardConversion(
            issueID: row["issue_id"], kind: kind,
            status: LegacyConversionStatus(rawValue: row["status"]) ?? .planned,
            detail: row["detail"], version: row["version"]
        )
    }

    /// Records (replacing) the conversion row, under the Act-scoped lease. Idempotent: the same row
    /// recorded twice leaves one.
    public func recordLegacyConversion(
        issueID: String, kind: LegacyConversionKind, status: LegacyConversionStatus, detail: String? = nil,
        version: Int, runID: RunID, now: Date = Date()
    ) throws {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO legacy_board_conversion (issue_id, kind, status, detail, version, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    issueID, kind.rawValue, status.rawValue, detail, version,
                    JournalStore.timestamp(JournalStore.stored(now))
                ]
            )
        }
    }

    /// The Operator edited the Card override field (the description's lines changed from what the Journal
    /// held): when a legacy conversion is still open for the Card, the edit resolves it, so a later sync
    /// can never restore the retired pin. Returns whether a row was completed.
    ///
    /// A `converted` row ignores the very line the migration wrote coming back through the import
    /// (`Card override: <pin>`); any other value, the empty form included, is the Operator's explicit
    /// set or clear. A `conflict` row is resolved by any edit.
    @discardableResult
    public func noteCardOverrideEdited(issueID: String, lines: [String]) throws -> Bool {
        try write { db in
            guard let row = try Self.legacyConversion(db, issueID: issueID, kind: .override),
                  row.status == .converted || row.status == .conflict
            else { return false }
            if row.status == .converted, let pin = row.detail,
               CardOverrideField.sameIgnoringEscapes(lines, [CardOverrideField.prefix + " " + pin]) {
                return false
            }
            try db.execute(
                sql: "UPDATE legacy_board_conversion SET status = ? WHERE issue_id = ? AND kind = ?",
                arguments: [LegacyConversionStatus.complete.rawValue, issueID, LegacyConversionKind.override.rawValue]
            )
            return true
        }
    }

    /// Whether the Journal tracks `issueID` as a Feature Issue or a Work Card. The migration touches only
    /// such issues; an issue the Journal does not hold is never read, written or unassigned.
    public func isTrackedIssue(_ issueID: String) throws -> Bool {
        try read { db in
            try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS(SELECT 1 FROM feature WHERE issue_id = ?)
                    OR EXISTS(SELECT 1 FROM card WHERE issue_id = ?)
                """,
                arguments: [issueID, issueID]
            ) ?? false
        }
    }
}
