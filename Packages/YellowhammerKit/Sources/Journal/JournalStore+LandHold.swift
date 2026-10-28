import Domain
import Foundation
import GRDB

/// A persisted span during which Work Cards kept the land Act from firing (OQ183).
public struct LandHoldRecord: Equatable, Sendable {
    public let id: Int64
    public let nightID: Int64
    public let cycleID: Int64
    public let cardIDs: [Int64]
    public let startedAt: Date
    public let endsAt: Date
    public let endedAt: Date?
    public let endReason: String?
    public let answerWaitMinutes: Int
}

extension JournalStore {
    public func landHolds(nightID: Int64) throws -> [LandHoldRecord] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM land_hold WHERE night_id = ? ORDER BY id", arguments: [nightID])
                .map(Self.landHoldRecord)
        }
    }

    public func activeLandHold(cycleID: Int64) throws -> LandHoldRecord? {
        try read { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM land_hold WHERE cycle_id = ? AND ended_at IS NULL ORDER BY id DESC LIMIT 1
                """,
                             arguments: [cycleID]).map(Self.landHoldRecord)
        }
    }

    private static func landHoldRecord(_ row: Row) throws -> LandHoldRecord {
        let ids: String = row["card_ids"]
        let start: String = row["started_at"]
        let end: String = row["ends_at"]
        let ended: String? = row["ended_at"]
        return LandHoldRecord(
            id: row["id"], nightID: row["night_id"], cycleID: row["cycle_id"],
            cardIDs: try JSONDecoder().decode([Int64].self, from: Data(ids.utf8)),
            startedAt: try Date(start, strategy: Self.timestampStyle),
            endsAt: try Date(end, strategy: Self.timestampStyle),
            endedAt: try ended.map { try Date($0, strategy: Self.timestampStyle) }, endReason: row["end_reason"],
            answerWaitMinutes: row["answer_wait_minutes"]
        )
    }

    /// The intent is durable before calling a push seam, including a process lost inside that call.
    public func hasCycleHandoffBegun(cycleID: Int64) throws -> Bool {
        try read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cycle_handoff WHERE cycle_id = ?)",
                              arguments: [cycleID]) ?? false
        }
    }

    public func beginCycleHandoff(cycleID: Int64, runID: RunID, now: Date = Date()) throws {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: Self.stored(now))
            try db.execute(sql: "INSERT OR IGNORE INTO cycle_handoff (cycle_id) VALUES (?)", arguments: [cycleID])
            if db.changesCount > 0 {
                _ = try Self.insertEvent(db, .landHoldChanged(cycleID: cycleID, detail: "Handoff begun"),
                                        stamp: EventStamp(act: .land, runID: runID, nightID: nil, now: now))
            }
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func recordLandHold(
        nightID: Int64, cycleID: Int64, cardIDs: [Int64], startedAt: Date, endsAt: Date,
        answerWaitMinutes: Int, runID: RunID, now: Date = Date()
    ) throws {
        let encoded = String(bytes: try JSONEncoder().encode(cardIDs), encoding: .utf8) ?? "[]"
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: Self.stored(now))
            try db.execute(sql: """
                INSERT INTO land_hold (night_id, cycle_id, card_ids, started_at, ends_at, answer_wait_minutes)
                SELECT ?, ?, ?, ?, ?, ? WHERE NOT EXISTS (
                    SELECT 1 FROM land_hold WHERE night_id = ? AND cycle_id = ? AND started_at = ?)
                """, arguments: [nightID, cycleID, encoded, Self.timestamp(startedAt),
                                  Self.timestamp(endsAt), answerWaitMinutes, nightID, cycleID,
                                  Self.timestamp(startedAt)])
            if db.changesCount > 0 {
                _ = try Self.insertEvent(db, .landHoldChanged(cycleID: cycleID,
                    detail: "Started: Cards \(encoded), Bound \(answerWaitMinutes)m, "
                        + "since \(Self.timestamp(startedAt))"),
                    stamp: EventStamp(act: nil, runID: runID, nightID: nightID, now: now))
            }
            guard let existing = try Row.fetchOne(db, sql: """
                SELECT card_ids, ends_at, answer_wait_minutes FROM land_hold
                WHERE night_id = ? AND cycle_id = ? AND ended_at IS NULL
                """, arguments: [nightID, cycleID]) else { return }
            let prior: String = existing["card_ids"] ?? "[]"
            let union = Set(try JSONDecoder().decode([Int64].self, from: Data(prior.utf8))).union(cardIDs).sorted()
            let allCards = String(bytes: try JSONEncoder().encode(union), encoding: .utf8) ?? "[]"
            let previousEnd: String? = existing["ends_at"]
            let previousBound: Int = existing["answer_wait_minutes"]
            if prior != allCards || previousEnd != Self.timestamp(endsAt) || previousBound != answerWaitMinutes {
                _ = try Self.insertEvent(db, .landHoldChanged(cycleID: cycleID,
                    detail: "Updated: Cards \(allCards), ends \(Self.timestamp(endsAt)), Bound \(answerWaitMinutes)m"),
                    stamp: EventStamp(act: nil, runID: runID, nightID: nightID, now: now))
            }
            try db.execute(sql: """
                UPDATE land_hold SET ends_at = ?, card_ids = ?, answer_wait_minutes = ?
                WHERE night_id = ? AND cycle_id = ? AND ended_at IS NULL
                """, arguments: [Self.timestamp(endsAt), allCards, answerWaitMinutes, nightID, cycleID])
        }
    }

    public func endLandHold(cycleID: Int64, reason: String, runID: RunID, now: Date = Date()) throws {
        guard try activeLandHold(cycleID: cycleID) != nil else { return }
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: Self.stored(now))
            let spans = try Row.fetchAll(db, sql: """
                SELECT night_id FROM land_hold WHERE cycle_id = ? AND ended_at IS NULL
                """,
                                         arguments: [cycleID])
            try db.execute(sql: """
                UPDATE land_hold SET ended_at = ?, end_reason = ? WHERE cycle_id = ? AND ended_at IS NULL
                """, arguments: [Self.timestamp(now), reason, cycleID])
            for span in spans {
                _ = try Self.insertEvent(db, .landHoldChanged(cycleID: cycleID, detail: "Ended: \(reason)"),
                                        stamp: EventStamp(act: nil, runID: runID, nightID: span["night_id"], now: now))
            }
        }
    }
}

extension JournalStore {
    public func hasNightHoldEnded(nightID: Int64) throws -> Bool {
        try read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM night_hold_ended WHERE night_id = ?)",
                              arguments: [nightID]) ?? false
        }
    }

    public func endNightHold(nightID: Int64, runID: RunID, now: Date = Date()) throws {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: Self.stored(now))
            try db.execute(sql: "INSERT OR IGNORE INTO night_hold_ended (night_id) VALUES (?)", arguments: [nightID])
            let spans = try Row.fetchAll(db, sql: """
                SELECT cycle_id FROM land_hold WHERE night_id = ? AND ended_at IS NULL
                """,
                                         arguments: [nightID])
            try db.execute(sql: """
                UPDATE land_hold SET ended_at = ?, end_reason = 'hold-ending firing'
                WHERE night_id = ? AND ended_at IS NULL
                """, arguments: [Self.timestamp(now), nightID])
            for span in spans {
                let event = JournalEvent.landHoldChanged(cycleID: span["cycle_id"], detail: "Ended: hold-ending firing")
                _ = try Self.insertEvent(db, event,
                                        stamp: EventStamp(act: .land, runID: runID, nightID: nightID, now: now))
            }
        }
    }
}
