import Domain
import Foundation
import GRDB

extension JournalStore {
    /// Project-local account backoff survives Acts and Nights. Vendor reset text is a hint only:
    /// the engine honours a hint that names its own zone, never an ambiguous local wall-clock
    /// time, and otherwise uses a bounded 30-minute delay (`UsageLimitReset`).
    public func recordUsageLimit(
        route: Route, resetHint: String?, runID: RunID, act: Act, nightID: Int64?, now: Date = Date()
    ) throws {
        try append(
            .routeUsageLimited(route: route.description, cli: route.cli,
                               until: UsageLimitReset.until(resetHint: resetHint, now: now),
                               resetHint: resetHint),
            act: act, runID: runID, nightID: nightID, now: now
        )
    }

    /// A backoff within `UsageLimitReset.cadenceGrace` of its end already counts as over.
    public func backingOffCLIs(asOf now: Date = Date()) throws -> Set<String> {
        let effectiveNow = now.addingTimeInterval(UsageLimitReset.cadenceGrace)
        return try read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(payload, '$.cli') FROM event
                WHERE type = ? AND json_extract(payload, '$.until') > ?
                """, arguments: [JournalEventType.routeUsageLimited.rawValue, JournalStore.timestamp(effectiveNow)])
            return Set(rows)
        }
    }

    /// The latest recorded backoff until-time for `cli`, or nil if none is recorded.
    public func cliBackoffUntil(cli: String) throws -> Date? {
        try read { db -> Date? in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, json_extract(payload, '$.until') AS until FROM event
                WHERE type = ? AND json_extract(payload, '$.cli') = ?
                ORDER BY id DESC LIMIT 1
                """, arguments: [JournalEventType.routeUsageLimited.rawValue, cli])
            else { return nil }
            let id: Int64 = row["id"]
            let timestamp: String = row["until"]
            return try JournalStore.date(timestamp) {
                JournalError.eventUnreadable(id: id)
            }
        }
    }

    /// Every Work Card currently Todo whose latest Attempt ended `usage limited`, paired with that
    /// Attempt, ordered by repository then authored order.
    public func usageLimitedHeldCards() throws -> [(card: CardRecord, attempt: AttemptRecord)] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM card
                WHERE state = ? AND removed_from_board IS NULL
                ORDER BY repository ASC, authored_order ASC
                """, arguments: [CardState.todo.rawValue])
            var result: [(CardRecord, AttemptRecord)] = []
            for row in rows {
                let card = try Self.cardRecord(from: row)
                guard let attemptRow = try Row.fetchOne(db, sql: """
                    SELECT id FROM attempt
                    WHERE card_id = ?
                    ORDER BY id DESC LIMIT 1
                    """, arguments: [card.id]),
                    let attempt = try Self.fetchAttempt(db, attemptID: attemptRow["id"]),
                    attempt.result == AttemptOutcome.usageLimited.rawValue
                else { continue }
                result.append((card, attempt))
            }
            return result
        }
    }
}
