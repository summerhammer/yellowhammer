import Domain
import GRDB

/// A short summary of a Card's Attempts and Rounds, for a pull request body (roadmap P10.4). Reads
/// only — no policy, no decision.
public struct CardAttemptSummary: Equatable, Sendable {
    /// The distinct routes attempted, in attempt order.
    public let routes: [Route]
    public let roundCount: Int
    /// The last `check` Round's verdict, when any Round of kind `check` was recorded.
    public let lastCheckVerdict: String?

    public var routeSummary: String {
        routes.isEmpty ? "none" : routes.map { "\($0.cli)/\($0.model)" }.joined(separator: ", ")
    }

    public var checkSummary: String {
        lastCheckVerdict.map { "checks: \($0)" } ?? "checks: none recorded"
    }
}

extension JournalStore {
    /// Summarises `cardID`'s Attempts and Rounds directly from `attempt`/`round`, for a pull request
    /// body's per-Card list. Never used to gate anything.
    public func attemptSummary(cardID: Int64) throws -> CardAttemptSummary {
        try read { db in
            let attemptRows = try Row.fetchAll(
                db,
                sql: "SELECT id, route_cli, route_model, route_effort FROM attempt WHERE card_id = ? ORDER BY id",
                arguments: [cardID]
            )
            let routes: [Route] = attemptRows.compactMap { row in
                Route(cli: row["route_cli"], model: row["route_model"], effort: row["route_effort"])
            }
            let attemptIDs: [Int64] = attemptRows.map { $0["id"] }
            guard !attemptIDs.isEmpty else {
                return CardAttemptSummary(routes: [], roundCount: 0, lastCheckVerdict: nil)
            }
            let placeholders = attemptIDs.map { _ in "?" }.joined(separator: ",")
            let roundRows = try Row.fetchAll(
                db,
                sql: """
                SELECT lens, verdict FROM round WHERE attempt_id IN (\(placeholders)) ORDER BY id
                """,
                arguments: StatementArguments(attemptIDs)
            )
            let lastCheckVerdict: String? = roundRows.last { ($0["lens"] as String) == "check" }
                .map { $0["verdict"] }
            return CardAttemptSummary(routes: routes, roundCount: roundRows.count, lastCheckVerdict: lastCheckVerdict)
        }
    }
}
