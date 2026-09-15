import Domain
import Foundation
import GRDB

/// A row of the event log as read back.
public struct JournalEventRecord: Equatable, Sendable {
    public let id: Int64
    public let event: JournalEvent
    public let act: Act?
    public let runID: RunID?
    public let nightID: Int64?
    public let occurredAt: Date

    /// The type of the event.
    public var type: JournalEventType { event.type }
}

/// Context for stamping an event: its associated Act, run, Night, and timestamp.
internal struct EventStamp: Sendable {
    let act: Act?
    let runID: RunID?
    let nightID: Int64?
    let now: Date
}

extension JournalStore {
    /// Appends one event. The log is append-only: nothing in this module updates or deletes a row, and the
    /// table's triggers refuse both. Returns the row id.
    @discardableResult
    public func append(
        _ event: JournalEvent,
        act: Act? = nil,
        runID: RunID? = nil,
        nightID: Int64? = nil,
        now: Date = Date()
    ) throws -> Int64 {
        try write { db in
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            return try Self.insertEvent(db, event, stamp: stamp)
        }
    }

    /// Every event in append order, optionally only those of one type.
    public func events(ofType type: JournalEventType? = nil) throws -> [JournalEventRecord] {
        try read { db in
            let rows: [Row]
            if let type {
                let sql = "SELECT * FROM event WHERE type = ? ORDER BY id ASC"
                rows = try Row.fetchAll(db, sql: sql, arguments: [type.rawValue])
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM event ORDER BY id ASC")
            }
            return try rows.map { row in
                let id: Int64 = row["id"]
                let typeRaw: String = row["type"]
                guard let eventType = JournalEventType(rawValue: typeRaw) else {
                    throw JournalError.eventUnreadable(id: id)
                }

                let payloadJSON: String? = row["payload"]
                let payload: [String: String]?
                if let payloadJSON {
                    let data = payloadJSON.data(using: .utf8) ?? Data()
                    payload = try JSONDecoder().decode([String: String].self, from: data)
                } else {
                    payload = nil
                }

                let event = try JournalEvent(type: eventType, payload: payload, rowID: id)

                let act: Act? = (row["act"] as String?).flatMap { Act(rawValue: $0) }
                let runID: RunID? = (row["run_id"] as String?).flatMap { RunID(rawValue: $0) }
                let nightID: Int64? = row["night_id"]
                let occurredAt = try Self.date(row["occurred_at"] as String? ?? "") {
                    JournalError.eventUnreadable(id: id)
                }

                return JournalEventRecord(
                    id: id,
                    event: event,
                    act: act,
                    runID: runID,
                    nightID: nightID,
                    occurredAt: occurredAt
                )
            }
        }
    }

    /// Internal: the insert, so that a lease takeover can record its reclaim in the same transaction.
    static func insertEvent(_ db: Database, _ event: JournalEvent, stamp: EventStamp) throws -> Int64 {
        let stored = Self.stored(stamp.now)
        let payloadJSON: String?

        if let payload = event.payload {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(payload)
            payloadJSON = String(data: data, encoding: .utf8)
        } else {
            payloadJSON = nil
        }

        try db.execute(
            sql: """
            INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                stamp.nightID,
                stamp.act?.rawValue,
                stamp.runID?.rawValue,
                event.type.rawValue,
                Self.timestamp(stored),
                payloadJSON
            ]
        )

        return db.lastInsertedRowID
    }
}
