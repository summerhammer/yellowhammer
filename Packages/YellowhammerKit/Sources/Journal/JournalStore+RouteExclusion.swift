import Domain
import Foundation
import GRDB

// The read route resolution filters by (routing/resolve-a-route-for-a-card, P7.6). The rows are
// written on capability failure by route exclusion on retry (routing/exclude-tried-routes-on-retry,
// P7.7); this only reads them.

extension JournalStore {
    /// The Routes attempt history excludes for `cardID` in its **current** budget epoch: the
    /// `route_exclusion` rows whose `budget_epoch` equals the Card's. An Override pinned in triage
    /// resets the epoch, so rows from an earlier epoch no longer exclude. Throws `cardUnknown` for a
    /// Card the Journal does not hold and `routeExclusionUnreadable` for a row that does not decode.
    public func excludedRoutes(cardID: Int64) throws -> Set<Route> {
        try read { db in
            guard let epoch = try Int.fetchOne(
                db, sql: "SELECT budget_epoch FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT route_cli, route_model, route_effort FROM route_exclusion
                WHERE card_id = ? AND budget_epoch = ?
                """,
                arguments: [cardID, epoch]
            )
            var routes: Set<Route> = []
            for row in rows {
                guard let route = Route(
                    cli: row["route_cli"], model: row["route_model"], effort: row["route_effort"]
                ) else {
                    throw JournalError.routeExclusionUnreadable(cardID: cardID)
                }
                routes.insert(route)
            }
            return routes
        }
    }
}
