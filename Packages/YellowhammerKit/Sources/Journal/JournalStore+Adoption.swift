import Domain
import Foundation
import GRDB

// The read behind feature selection's adoption candidates (roadmap P9.3; spec:
// feature-authoring/select-the-next-feature, first story): Cards left Blocked by a closed Feature.

extension JournalStore {
    /// Every Card whose state is exactly Blocked and whose Cycle is archived — left behind by a closed
    /// Feature, and a candidate this Night's selection may adopt. A Shelved Card is never returned
    /// (it is not Blocked, so it never satisfies this filter), nor is a removed one (trashed, or archived
    /// while in play; OQ142): it is set aside, not adopted; a Blocked Card in the open Cycle is
    /// never returned (its Cycle is not yet archived). Ordered by repository then authored order, for
    /// a stable, readable candidate list.
    public func blockedCardsLeftByClosedFeatures() throws -> [CardRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT card.* FROM card
                JOIN cycle ON cycle.id = card.cycle_id
                WHERE card.state = ? AND cycle.archived_at IS NOT NULL AND card.removed_from_board IS NULL
                ORDER BY card.repository ASC, card.authored_order ASC
                """,
                arguments: [CardState.blocked.rawValue]
            )
            return try rows.map { try Self.cardRecord(from: $0) }
        }
    }

    /// Every Card adopted into the Feature whose Feature Issue is `featureIssueID`, mapped to the
    /// `previous_feature_issue_id` of its (latest, if more than one) `CardAdopted` event (spec ruling
    /// OQ182, item 5): the same-repository hold reads it to keep an adopted Card's sequence apart from
    /// a newly authored one's. Reads the stored events directly — no column, no migration.
    public func adoptionOrigins(featureIssueID: String) throws -> [Int64: String] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT json_extract(payload, '$.card_id') AS card_id,
                       json_extract(payload, '$.previous_feature_issue_id') AS previous_feature_issue_id
                FROM event
                WHERE type = ? AND json_extract(payload, '$.new_feature_issue_id') = ?
                ORDER BY id ASC
                """,
                arguments: [JournalEventType.cardAdopted.rawValue, featureIssueID]
            )
            var origins: [Int64: String] = [:]
            for row in rows {
                guard
                    let cardIDText: String = row["card_id"], let cardID = Int64(cardIDText),
                    let previousFeatureIssueID: String = row["previous_feature_issue_id"]
                else { continue }
                // Ascending order, so a Card adopted more than once has its latest event win.
                origins[cardID] = previousFeatureIssueID
            }
            return origins
        }
    }

    /// Every Card whose recorded `CardAdopted` event names `fromFeatureIssueID` as the Feature it left
    /// (`previous_feature_issue_id`) — no longer in that Feature's old Cycle, so the same-repository
    /// sequence gate (spec ruling OQ182, item 6) cannot find it there. Read live from `card` (current
    /// repository, title and state), with `authoredOrder` substituted by the position that event
    /// recorded it held before it left (``CardRecord/with(authoredOrder:)``) — `Int.min` when the event
    /// predates this field (a Journal written before this change): unprovable, so it is placed ahead of
    /// every candidate rather than let through silently. A Card leaves a Feature at most once, so this
    /// never needs a tie-break between two such events for the same Card.
    public func cardsAdoptedAway(fromFeatureIssueID: String) throws -> [CardRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT json_extract(payload, '$.card_id') AS card_id,
                       json_extract(payload, '$.previous_authored_order') AS previous_authored_order
                FROM event
                WHERE type = ? AND json_extract(payload, '$.previous_feature_issue_id') = ?
                """,
                arguments: [JournalEventType.cardAdopted.rawValue, fromFeatureIssueID]
            )
            var cards: [CardRecord] = []
            for row in rows {
                guard let cardIDText: String = row["card_id"], let cardID = Int64(cardIDText) else { continue }
                let orderText: String? = row["previous_authored_order"]
                let order = orderText.flatMap { Int($0) } ?? Int.min
                guard let cardRow = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID])
                else {
                    continue
                }
                cards.append(try Self.cardRecord(from: cardRow).with(authoredOrder: order))
            }
            return cards
        }
    }
}
