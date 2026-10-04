import Domain
import Foundation
import GRDB

// A Linear issue's board URL and identifier (issue #230), kept in its own file so
// JournalStore+Cards.swift stays under the file-length limit.

/// Where an issue's key and url are kept: the table and its issue id, key and url columns.
private struct IssueLinkTarget {
    let table: String
    let idColumn: String
    let keyColumn: String
    let urlColumn: String
}

extension JournalStore {
    private static let issueLinkTargets = [
        IssueLinkTarget(table: "card", idColumn: "issue_id", keyColumn: "issue_key", urlColumn: "issue_url"),
        IssueLinkTarget(table: "feature", idColumn: "issue_id", keyColumn: "issue_key", urlColumn: "issue_url"),
        IssueLinkTarget(
            table: "night", idColumn: "night_card_issue_id", keyColumn: "night_card_issue_key",
            urlColumn: "night_card_issue_url"
        )
    ]

    /// The Delta Read saw the issue `issueID` on the board: records Linear's `identifier` (`key`) and
    /// board `url` on every Card, Feature and Night Card row of this Journal that holds that issue,
    /// under the Act-scoped lease. No event: a link is not loop state any Act decision branches on, the
    /// same idiom as ``updateCardTitle(cardID:title:runID:now:)``.
    ///
    /// One write transaction. A row whose stored key and url already equal these is not written, so a
    /// repeat Delta Read of an unchanged issue writes nothing. Returns true when any row changed, false
    /// for an issue id the Journal does not hold or a link already recorded.
    @discardableResult
    public func recordIssueLink(
        issueID: String,
        key: String,
        url: String,
        runID: RunID,
        now: Date = Date()
    ) throws -> Bool {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            var changed = false
            for target in Self.issueLinkTargets {
                try db.execute(
                    sql: """
                    UPDATE \(target.table) SET \(target.keyColumn) = ?, \(target.urlColumn) = ?
                    WHERE \(target.idColumn) = ?
                      AND (\(target.keyColumn) IS NOT ? OR \(target.urlColumn) IS NOT ?)
                    """,
                    arguments: [key, url, issueID, key, url]
                )
                if db.changesCount > 0 { changed = true }
            }
            return changed
        }
    }
}
