import Domain
import Foundation
import GRDB

// The Journal side of the Authoring Halt (roadmap P9.8; glossary: Authoring Halt): authoring stopped for
// a reason that is not a thin specification. Shaped like the Refusal store — tracked per Feature name,
// same Night-driven unanswered-Nights clock — but a halt has no consecutive count of any kind and no
// `answered` state: it leaves the clock only when that Feature next authors cleanly.

/// An Authoring Halt as the Journal holds it.
public struct AuthoringHaltRecord: Equatable, Sendable {
    public let id: Int64
    public let featureName: String
    public let issueID: String?
    public let state: AuthoringHaltState
    /// ``AuthoringHaltCause/kind``.
    public let causeKind: String
    /// The cause's description, kept so it survives expiry.
    public let content: String
    public let openedNightID: Int64
    public let unansweredNights: Int
    public let lastCountedNightID: Int64?
    public let expiredNightID: Int64?
    public let createdAt: Date
}

public enum AuthoringHaltState: String, Equatable, Sendable {
    case open
    case expired
    case cleared
}

/// What `recordAuthoringHalt` found and did.
public struct AuthoringHaltOutcome: Equatable, Sendable {
    public let record: AuthoringHaltRecord
    /// True when a new `open` row was inserted.
    public let newlyOpened: Bool
    /// True when the Feature's latest halt was already `expired`: nothing changed, and no board write
    /// follows from this call.
    public let alreadyExpired: Bool
}

extension JournalStore {
    /// Records one Authoring Halt against `feature`:
    ///
    /// - An `open` halt gets its content replaced; the clock is left exactly as it was — a repeat halt
    ///   never restarts it. Appends `authoringHaltRepeated`.
    /// - A latest-`expired` halt is left alone entirely (`alreadyExpired`); appends `authoringHaltRepeated`
    ///   for the record only.
    /// - Otherwise a new `open` row is inserted and `authoringHaltOpened` appended.
    ///
    /// Never touches a Refusal or any consecutive count.
    @discardableResult
    public func recordAuthoringHalt(
        feature: FeatureName, causeKind: String, detail: String? = nil, content: String, nightID: Int64,
        act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> AuthoringHaltOutcome {
        try write { db in
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
            let repeated = JournalEvent.authoringHaltRepeated(
                feature: feature.rawValue, causeKind: causeKind, detail: detail
            )

            if let openRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM authoring_halt WHERE feature_name = ? AND state = 'open'",
                arguments: [feature.rawValue]
            ) {
                let id: Int64 = openRow["id"]
                try db.execute(
                    sql: "UPDATE authoring_halt SET content = ?, cause_kind = ? WHERE id = ?",
                    arguments: [content, causeKind, id]
                )
                _ = try Self.insertEvent(db, repeated, stamp: stamp)
                let record = try Self.authoringHaltRecord(from: try Self.fetchAuthoringHaltRow(db, id: id))
                return AuthoringHaltOutcome(record: record, newlyOpened: false, alreadyExpired: false)
            }

            let latestRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM authoring_halt WHERE feature_name = ? ORDER BY id DESC LIMIT 1",
                arguments: [feature.rawValue]
            )
            if let latestRow, (latestRow["state"] as String) == AuthoringHaltState.expired.rawValue {
                _ = try Self.insertEvent(db, repeated, stamp: stamp)
                let record = try Self.authoringHaltRecord(from: latestRow)
                return AuthoringHaltOutcome(record: record, newlyOpened: false, alreadyExpired: true)
            }

            try db.execute(
                sql: """
                INSERT INTO authoring_halt (
                    feature_name, state, cause_kind, content, opened_night_id, unanswered_nights, created_at
                ) VALUES (?, 'open', ?, ?, ?, 0, ?)
                """,
                arguments: [feature.rawValue, causeKind, content, nightID, JournalStore.timestamp(stamp.now)]
            )
            let id = db.lastInsertedRowID
            _ = try Self.insertEvent(
                db, .authoringHaltOpened(feature: feature.rawValue, causeKind: causeKind, detail: detail),
                stamp: stamp
            )
            let record = try Self.authoringHaltRecord(from: try Self.fetchAuthoringHaltRow(db, id: id))
            return AuthoringHaltOutcome(record: record, newlyOpened: true, alreadyExpired: false)
        }
    }

    /// Stores the Feature Issue's id on the most recently recorded halt for `feature`. A no-op when the
    /// Feature has no halt row.
    public func recordAuthoringHaltIssue(feature: FeatureName, issueID: String) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE authoring_halt SET issue_id = ?
                WHERE id = (SELECT MAX(id) FROM authoring_halt WHERE feature_name = ?)
                """,
                arguments: [issueID, feature.rawValue]
            )
        }
    }

    /// Advances every `open` halt's unanswered-Nights clock by one Night, with exactly the Refusal
    /// clock's arithmetic (bounds/bound-unanswered-nights): Night-driven, idempotent within a Night, the
    /// opening Night never counts, and a halt expires strictly PAST `unansweredNightsMax`, keeping its
    /// content. Appends `authoringHaltExpired` for each; returns the newly expired.
    @discardableResult
    public func advanceAuthoringHaltClocks(
        nightID: Int64, unansweredNightsMax: Int, act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> [AuthoringHaltRecord] {
        try write { db in
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM authoring_halt
                WHERE state = 'open' AND opened_night_id != ?
                  AND (last_counted_night_id IS NULL OR last_counted_night_id != ?)
                """,
                arguments: [nightID, nightID]
            )
            var expired: [AuthoringHaltRecord] = []
            for row in rows {
                let id: Int64 = row["id"]
                let unansweredNights: Int = row["unanswered_nights"]
                let newCount = unansweredNights + 1
                guard newCount > unansweredNightsMax else {
                    try db.execute(
                        sql: "UPDATE authoring_halt SET unanswered_nights = ?, last_counted_night_id = ? WHERE id = ?",
                        arguments: [newCount, nightID, id]
                    )
                    continue
                }
                try db.execute(
                    sql: """
                    UPDATE authoring_halt
                    SET unanswered_nights = ?, last_counted_night_id = ?, state = 'expired', expired_night_id = ?
                    WHERE id = ?
                    """,
                    arguments: [newCount, nightID, nightID, id]
                )
                _ = try Self.insertEvent(
                    db,
                    .authoringHaltExpired(
                        feature: row["feature_name"], issueID: row["issue_id"], unansweredNights: newCount,
                        bound: unansweredNightsMax
                    ),
                    stamp: stamp
                )
                expired.append(try Self.authoringHaltRecord(from: try Self.fetchAuthoringHaltRow(db, id: id)))
            }
            return expired
        }
    }

    /// A clean authoring run for `feature` clears its `open` and `expired` halts, taking them off the
    /// clock. Appends `authoringHaltCleared` only when it cleared something; returns whether it did.
    @discardableResult
    public func clearAuthoringHalts(
        feature: FeatureName, nightID: Int64? = nil, act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            try db.execute(
                sql: """
                UPDATE authoring_halt SET state = 'cleared'
                WHERE feature_name = ? AND state IN ('open','expired')
                """,
                arguments: [feature.rawValue]
            )
            guard db.changesCount > 0 else { return false }
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
            _ = try Self.insertEvent(db, .authoringHaltCleared(feature: feature.rawValue), stamp: stamp)
            return true
        }
    }

    /// Every currently `open` halt, oldest first.
    public func openAuthoringHalts() throws -> [AuthoringHaltRecord] {
        try authoringHalts(where: "state = 'open'")
    }

    /// Every `expired` halt, oldest first. The author Act re-posts each one's Blocked board update
    /// under its idempotent Outbox key, so an Act killed between the expiry and the post loses nothing.
    public func expiredAuthoringHalts() throws -> [AuthoringHaltRecord] {
        try authoringHalts(where: "state = 'expired'")
    }

    /// Every halt recorded for `feature`, oldest first.
    public func authoringHalts(feature: FeatureName) throws -> [AuthoringHaltRecord] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM authoring_halt WHERE feature_name = ? ORDER BY id ASC",
                arguments: [feature.rawValue]
            ).map { try Self.authoringHaltRecord(from: $0) }
        }
    }

    private func authoringHalts(where condition: String) throws -> [AuthoringHaltRecord] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM authoring_halt WHERE \(condition) ORDER BY id ASC")
                .map { try Self.authoringHaltRecord(from: $0) }
        }
    }

    private static func fetchAuthoringHaltRow(_ db: Database, id: Int64) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM authoring_halt WHERE id = ?", arguments: [id]) else {
            throw JournalError.authoringHaltUnreadable(id: id)
        }
        return row
    }

    private static func authoringHaltRecord(from row: Row) throws -> AuthoringHaltRecord {
        let id: Int64 = row["id"]
        let stateRaw: String = row["state"]
        guard let state = AuthoringHaltState(rawValue: stateRaw) else {
            throw JournalError.authoringHaltUnreadable(id: id)
        }
        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.authoringHaltUnreadable(id: id) }
        return AuthoringHaltRecord(
            id: id,
            featureName: row["feature_name"],
            issueID: row["issue_id"],
            state: state,
            causeKind: row["cause_kind"],
            content: row["content"],
            openedNightID: row["opened_night_id"],
            unansweredNights: row["unanswered_nights"],
            lastCountedNightID: row["last_counted_night_id"],
            expiredNightID: row["expired_night_id"],
            createdAt: createdAt
        )
    }
}
