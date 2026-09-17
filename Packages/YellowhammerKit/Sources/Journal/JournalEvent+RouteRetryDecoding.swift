import Domain
import Foundation

// The route exclusion on retry events' decode helpers (routing/exclude-tried-routes-on-retry, P7.7),
// split out of JournalEvent+Decoding.swift (whose exhaustive switch still dispatches to them) to keep
// that file under the file length limit.

extension JournalEvent {
    static func decodeAttemptEnded(_ reader: PayloadReader) throws -> JournalEvent {
        .attemptEnded(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            route: try reader.route(),
            outcome: try reader.require("outcome"),
            routeExcluded: try reader.bool("route_excluded")
        )
    }

    static func decodeRouteRetried(_ reader: PayloadReader) throws -> JournalEvent {
        .routeRetried(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            route: try reader.route(),
            differentRoute: try reader.bool("different_route")
        )
    }

    static func decodeBudgetEpochReset(_ reader: PayloadReader) throws -> JournalEvent {
        .budgetEpochReset(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            from: try reader.int("from_epoch"),
            to: try reader.int("to_epoch"),
            reason: try reader.require("reason")
        )
    }
}
