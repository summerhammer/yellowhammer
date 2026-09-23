import Domain
import GRDB

public enum OpeningReadyState: String, Equatable, Sendable {
    case zero
    case nonzero
    case unknown
}

public struct OpeningReadyCounts: Equatable, Sendable {
    public let zero: Int
    public let nonzero: Int
    public let unknown: Int
}

public struct ClosingCardBoundCounters: Equatable, Sendable {
    public let unanswered: Int
    public let failedAdoptions: Int
}

extension JournalStore {
    /// The first opening observation wins. A later Act never replaces it.
    public func recordOpeningReadyState(nightID: Int64, state: OpeningReadyState) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE night SET opening_ready_state = ? WHERE id = ? AND opening_ready_state IS NULL",
                arguments: [state.rawValue, nightID]
            )
        }
    }

    public func openingReadyState(nightID: Int64) throws -> OpeningReadyState {
        try read { db in
            let raw = try String.fetchOne(
                db, sql: "SELECT opening_ready_state FROM night WHERE id = ?", arguments: [nightID]
            )
            return raw.flatMap(OpeningReadyState.init(rawValue:)) ?? .unknown
        }
    }

    /// Counts this Project's opening observations through the named Night. Older Nights with no
    /// snapshot are unknown, as are reads that explicitly failed.
    public func openingReadyCounts(through nightStart: NightStart) throws -> OpeningReadyCounts {
        try read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN opening_ready_state = 'zero' THEN 1 ELSE 0 END) AS zero_count,
                       SUM(CASE WHEN opening_ready_state = 'nonzero' THEN 1 ELSE 0 END) AS nonzero_count
                FROM night WHERE project_id = ? AND night_start <= ?
                """,
                arguments: [projectID.rawValue, nightStart.rawValue]
            )
            let total: Int = row?["total"] ?? 0
            let zero: Int = row?["zero_count"] ?? 0
            let nonzero: Int = row?["nonzero_count"] ?? 0
            return OpeningReadyCounts(zero: zero, nonzero: nonzero, unknown: total - zero - nonzero)
        }
    }

    public func provenEmptyOpeningCount(through nightStart: NightStart) throws -> Int {
        try openingReadyCounts(through: nightStart).zero
    }

    /// The immutable Card-counter snapshot written in the same transaction as `night_end` closure.
    public func closingCardBoundCounters(nightID: Int64) throws -> ClosingCardBoundCounters? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT closing_unanswered_max, closing_failed_adoptions_max FROM night WHERE id = ?",
                arguments: [nightID]
            ) else { return nil }
            guard let unanswered: Int = row["closing_unanswered_max"],
                  let adoptions: Int = row["closing_failed_adoptions_max"] else { return nil }
            return ClosingCardBoundCounters(unanswered: unanswered, failedAdoptions: adoptions)
        }
    }
}
