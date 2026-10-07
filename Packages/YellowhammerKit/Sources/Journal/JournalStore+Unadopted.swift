import Domain
import Foundation
import GRDB

// The un-adopted-Cards standing line (roadmap P12.1; spec: morning-report/write-the-night-summary):
// a Card left Blocked by a closed Feature, named on the Night Summary and on its own Managed Block
// header. Both renderers read the ONE derivation here, so the two figures can never disagree.

/// A Card left Blocked by a closed Feature. Reported only, never acted on.
public struct UnadoptedCard: Equatable, Sendable {
    public let card: CardRecord
    /// The Feature whose Cycle archived, leaving this Card Blocked and un-adopted.
    public let closedFeatureIssueID: String
    /// Nights elapsed since the closing Night, up to and including the reference Night.
    public let elapsedNights: Int
}

extension JournalStore {
    /// Every Card left Blocked by a closed Feature, as of `nightStart`: `blockedCardsLeftByClosedFeatures()`
    /// carries the state/archived-Cycle predicate; this adds each Card's closed Feature and elapsed
    /// Nights. Ordered the same way — by repository, then authored order. A Card whose Cycle's
    /// `archived_at` cannot be read is skipped rather than guessed at.
    public func unadoptedCards(asOf nightStart: NightStart) throws -> [UnadoptedCard] {
        try blockedCardsLeftByClosedFeatures().compactMap { card in
            guard let closedFeatureIssueID = try closedFeatureIssueID(cycleID: card.cycleID) else { return nil }
            guard let elapsed = try unadoptedNights(cardID: card.id, asOf: nightStart) else { return nil }
            return UnadoptedCard(card: card, closedFeatureIssueID: closedFeatureIssueID, elapsedNights: elapsed)
        }
    }

    /// Nights elapsed since a Blocked, un-adopted Card's closing Night, up to and including
    /// `nightStart`; nil when the Card is not un-adopted — not Blocked, removed from the board, or its Cycle not archived, the
    /// same predicate `blockedCardsLeftByClosedFeatures()` filters on.
    ///
    /// The closing Night is the latest Night whose `opened_at` is at or before the Card's Cycle's
    /// `archived_at`. Elapsed is the count of recorded Nights whose `night_start` is strictly after
    /// the closing Night's, up to and including `nightStart` — derived at read time from the Night
    /// table alone; nothing is written to store it.
    public func unadoptedNights(cardID: Int64, asOf nightStart: NightStart) throws -> Int? {
        try read { db in
            guard let cardRow = try Row.fetchOne(
                db, sql: "SELECT state, cycle_id, removed_from_board FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            // A removed Card (OQ142) is not un-adopted work: its count is suspended, not elapsed.
            guard (cardRow["removed_from_board"] as String?) == nil else { return nil }
            guard (cardRow["state"] as String) == CardState.blocked.rawValue else { return nil }
            let cycleID: Int64 = cardRow["cycle_id"]
            guard
                let cycleRow = try Row.fetchOne(
                    db, sql: "SELECT archived_at FROM cycle WHERE id = ?", arguments: [cycleID]
                ),
                let archivedAtText = cycleRow["archived_at"] as String?
            else {
                return nil
            }
            let archivedAt = try Self.date(archivedAtText) { JournalError.cardUnreadable(id: cardID) }

            let nightRows = try Row.fetchAll(
                db,
                sql: "SELECT night_start, opened_at FROM night WHERE project_id = ? ORDER BY night_start ASC",
                arguments: [projectID.rawValue]
            )
            var closingNightStart: NightStart?
            for row in nightRows {
                guard let recordedStart = NightStart(rawValue: row["night_start"]) else { continue }
                let openedAt = try Self.date(row["opened_at"]) { JournalError.cardUnreadable(id: cardID) }
                if openedAt <= archivedAt {
                    // Ascending order: the last Night that still qualifies is the latest one, so this
                    // simply keeps overwriting rather than comparing against a running maximum.
                    closingNightStart = recordedStart
                }
            }
            guard let closingNightStart else { return nil }

            return nightRows.reduce(into: 0) { count, row in
                guard let recordedStart = NightStart(rawValue: row["night_start"]) else { return }
                if recordedStart > closingNightStart, recordedStart <= nightStart {
                    count += 1
                }
            }
        }
    }

    /// The issue id of the Feature whose Cycle `cycleID` is, or nil when either row is unreadable.
    private func closedFeatureIssueID(cycleID: Int64) throws -> String? {
        try read { db in
            guard
                let cycleRow = try Row.fetchOne(
                    db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID]
                )
            else {
                return nil
            }
            let featureID: Int64 = cycleRow["feature_id"]
            return try String.fetchOne(db, sql: "SELECT issue_id FROM feature WHERE id = ?", arguments: [featureID])
        }
    }
}
