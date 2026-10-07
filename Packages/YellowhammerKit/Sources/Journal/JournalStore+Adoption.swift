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
}
