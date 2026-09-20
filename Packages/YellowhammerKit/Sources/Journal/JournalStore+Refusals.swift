import Domain
import Foundation
import GRDB

// The Journal side of the Refusal (roadmap P9.7; glossary: Refusal): the author Act's finding that a
// Feature is too thin to yield citable Definition of Done clauses. Tracked per Feature name, because a
// Refusal can exist before the Journal has a `feature` row for it — the Feature Issue is created in
// Waiting on You before authoring is ever accepted into the Outbox. This phase implements `open`,
// `answered` and `expired`; `standing_item` (the refusal-drift promotion Bound) is P11.6's.

/// A Refusal as the Journal holds it.
public struct RefusalRecord: Equatable, Sendable {
    public let id: Int64
    public let featureName: String
    public let issueID: String?
    public let state: RefusalState
    /// The halt reason's content (detail and/or description), kept so it survives expiry.
    public let content: String
    public let openedNightID: Int64
    public let unansweredNights: Int
    public let lastCountedNightID: Int64?
    public let consecutiveRefusals: Int
    public let expiredNightID: Int64?
    public let createdAt: Date
}

/// The lifecycle states the glossary names for a Refusal. `standingItem` is stored but not yet
/// transitioned into by anything in this phase — that is P11.6's refusal-drift promotion Bound.
public enum RefusalState: String, Equatable, Sendable {
    case open
    case answered
    case expired
    case standingItem = "standing_item"
}

/// What `recordRefusal` found and did.
public struct RefusalOutcome: Equatable, Sendable {
    public let record: RefusalRecord
    /// True when no Refusal existed for this Feature name (or the latest one was answered) and a new
    /// `open` row was inserted.
    public let newlyOpened: Bool
    /// True when the Feature's latest Refusal was already `expired`: the consecutive count moved, but
    /// nothing else did, and no board write follows from this call.
    public let alreadyExpired: Bool
}

extension JournalStore {
    /// Records one uncitable-Definition-of-Done halt against `feature` (roadmap P9.7):
    ///
    /// - An `open` Refusal for this Feature name gets its consecutive count incremented and its
    ///   content replaced; the clock (`unanswered_nights`, `opened_night_id`) is left exactly as it
    ///   was — a repeat refusal must never restart it.
    /// - An `expired` Refusal (the latest recorded for this Feature name) gets only its consecutive
    ///   count incremented; it stays `expired`.
    /// - Otherwise a new `open` row is inserted, its consecutive count one more than the previous
    ///   row's (zero once ``resetConsecutiveRefusals(feature:nightID:act:runID:)`` has run, so this is 1).
    ///
    /// Appends `refusalOpened` or `refusalRepeated` in the same transaction as the row write.
    @discardableResult
    public func recordRefusal(
        feature: FeatureName, content: String, nightID: Int64, act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> RefusalOutcome {
        try write { db in
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))

            if let openRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM refusal WHERE feature_name = ? AND state = 'open'",
                arguments: [feature.rawValue]
            ) {
                let record = try Self.repeatRefusal(
                    db, row: openRow, feature: feature, content: content, stamp: stamp
                )
                return RefusalOutcome(record: record, newlyOpened: false, alreadyExpired: false)
            }

            let latestRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM refusal WHERE feature_name = ? ORDER BY id DESC LIMIT 1",
                arguments: [feature.rawValue]
            )

            if let latestRow, (latestRow["state"] as String) == RefusalState.expired.rawValue {
                let record = try Self.repeatRefusal(
                    db, row: latestRow, feature: feature, content: nil, stamp: stamp
                )
                return RefusalOutcome(record: record, newlyOpened: false, alreadyExpired: true)
            }

            let previousCount: Int = latestRow.map { $0["consecutive_refusals"] } ?? 0
            let newCount = previousCount + 1
            try db.execute(
                sql: """
                INSERT INTO refusal (
                    feature_name, state, content, opened_night_id, unanswered_nights, consecutive_refusals,
                    created_at
                ) VALUES (?, 'open', ?, ?, 0, ?, ?)
                """,
                arguments: [feature.rawValue, content, nightID, newCount, JournalStore.timestamp(stamp.now)]
            )
            let id = db.lastInsertedRowID
            _ = try Self.insertEvent(
                db, .refusalOpened(feature: feature.rawValue, consecutiveRefusals: newCount), stamp: stamp
            )
            let record = try Self.refusalRecord(from: try Self.fetchRefusalRow(db, id: id))
            return RefusalOutcome(record: record, newlyOpened: true, alreadyExpired: false)
        }
    }

    /// Bumps one existing Refusal row's consecutive count by one, optionally replacing its content
    /// (only ever done for the `open` row — a repeat against an `expired` row keeps its original
    /// content, per the Refusal glossary entry), and appends `refusalRepeated`. Split out of
    /// ``recordRefusal(feature:content:nightID:act:runID:now:)`` to keep that function within the
    /// length limit.
    private static func repeatRefusal(
        _ db: Database, row: Row, feature: FeatureName, content: String?, stamp: EventStamp
    ) throws -> RefusalRecord {
        let id: Int64 = row["id"]
        let current: Int = row["consecutive_refusals"]
        let newCount = current + 1
        if let content {
            try db.execute(
                sql: "UPDATE refusal SET consecutive_refusals = ?, content = ? WHERE id = ?",
                arguments: [newCount, content, id]
            )
        } else {
            try db.execute(
                sql: "UPDATE refusal SET consecutive_refusals = ? WHERE id = ?", arguments: [newCount, id]
            )
        }
        _ = try Self.insertEvent(
            db, .refusalRepeated(feature: feature.rawValue, consecutiveRefusals: newCount), stamp: stamp
        )
        return try Self.refusalRecord(from: try Self.fetchRefusalRow(db, id: id))
    }

    /// Stores the Feature Issue's id on the most recently recorded Refusal for `feature`, once the
    /// board's create has applied. A no-op when the Feature has no Refusal row.
    public func recordRefusalIssue(feature: FeatureName, issueID: String) throws {
        try write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT id FROM refusal WHERE feature_name = ? ORDER BY id DESC LIMIT 1",
                    arguments: [feature.rawValue]
                )
            else {
                return
            }
            let id: Int64 = row["id"]
            try db.execute(sql: "UPDATE refusal SET issue_id = ? WHERE id = ?", arguments: [issueID, id])
        }
    }

    /// Advances every `open` Refusal's unanswered-Nights clock by one Night (bounds/
    /// bound-unanswered-nights): purely Night-driven, no dates and no catch-up for a Night that never
    /// ran. Idempotent within a Night — a second author Act of the same Night adds nothing, because a
    /// row already counted for `nightID` is excluded. The Night a Refusal opened on never counts.
    ///
    /// A Refusal whose `unanswered_nights` now exceeds `unansweredNightsMax` becomes `expired`,
    /// appending `refusalExpired`; its content is kept. Returns every Refusal newly expired by this call.
    @discardableResult
    public func advanceRefusalClocks(
        nightID: Int64, unansweredNightsMax: Int, act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> [RefusalRecord] {
        try write { db in
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM refusal
                WHERE state = 'open' AND opened_night_id != ?
                  AND (last_counted_night_id IS NULL OR last_counted_night_id != ?)
                """,
                arguments: [nightID, nightID]
            )

            var expired: [RefusalRecord] = []
            for row in rows {
                if let record = try Self.advanceOneRefusalClock(
                    db, row: row, nightID: nightID, unansweredNightsMax: unansweredNightsMax, stamp: stamp
                ) {
                    expired.append(record)
                }
            }
            return expired
        }
    }

    /// Advances one `open` Refusal row's clock by this Night: returns the updated record only when it
    /// expired, so the caller collects just the newly-expired ones. Split out of
    /// ``advanceRefusalClocks(nightID:unansweredNightsMax:act:runID:now:)`` to keep that function within
    /// the length limit.
    private static func advanceOneRefusalClock(
        _ db: Database, row: Row, nightID: Int64, unansweredNightsMax: Int, stamp: EventStamp
    ) throws -> RefusalRecord? {
        let id: Int64 = row["id"]
        let unansweredNights: Int = row["unanswered_nights"]
        let newCount = unansweredNights + 1

        guard newCount > unansweredNightsMax else {
            try db.execute(
                sql: "UPDATE refusal SET unanswered_nights = ?, last_counted_night_id = ? WHERE id = ?",
                arguments: [newCount, nightID, id]
            )
            return nil
        }

        try db.execute(
            sql: """
            UPDATE refusal
            SET unanswered_nights = ?, last_counted_night_id = ?, state = 'expired', expired_night_id = ?
            WHERE id = ?
            """,
            arguments: [newCount, nightID, nightID, id]
        )
        let featureName: String = row["feature_name"]
        let issueID: String? = row["issue_id"]
        _ = try Self.insertEvent(
            db,
            .refusalExpired(
                feature: featureName, issueID: issueID, unansweredNights: newCount, bound: unansweredNightsMax
            ),
            stamp: stamp
        )
        return try Self.refusalRecord(from: try Self.fetchRefusalRow(db, id: id))
    }

    /// A clean authoring run for `feature` resets its consecutive-refusals count to zero on every one
    /// of its rows, and moves its `open` row (if any) to `answered` — never touching another Feature's
    /// rows. Appends `refusalCountReset` only when there was something to reset; returns whether it did.
    @discardableResult
    public func resetConsecutiveRefusals(
        feature: FeatureName, nightID: Int64? = nil, act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, state, consecutive_refusals FROM refusal WHERE feature_name = ?",
                arguments: [feature.rawValue]
            )
            guard !rows.isEmpty else { return false }

            var changed = false
            for row in rows {
                let id: Int64 = row["id"]
                let state: String = row["state"]
                let count: Int = row["consecutive_refusals"]
                if count != 0 {
                    try db.execute(sql: "UPDATE refusal SET consecutive_refusals = 0 WHERE id = ?", arguments: [id])
                    changed = true
                }
                if state == RefusalState.open.rawValue {
                    try db.execute(sql: "UPDATE refusal SET state = 'answered' WHERE id = ?", arguments: [id])
                    changed = true
                }
            }

            if changed {
                let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
                _ = try Self.insertEvent(db, .refusalCountReset(feature: feature.rawValue), stamp: stamp)
            }
            return changed
        }
    }

    /// The consecutive-refusals count on the latest Refusal recorded for `feature`, 0 when it has none.
    public func consecutiveRefusals(feature: FeatureName) throws -> Int {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT consecutive_refusals FROM refusal WHERE feature_name = ? ORDER BY id DESC LIMIT 1",
                    arguments: [feature.rawValue]
                )
            else {
                return 0
            }
            return row["consecutive_refusals"]
        }
    }

    /// Every currently `open` Refusal, oldest first.
    public func openRefusals() throws -> [RefusalRecord] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM refusal WHERE state = 'open' ORDER BY id ASC")
                .map { try Self.refusalRecord(from: $0) }
        }
    }

    /// Every `expired` Refusal, oldest first. The author Act re-posts each one's Blocked board update
    /// under its idempotent Outbox key, so an Act killed between the expiry and the post loses nothing.
    public func expiredRefusals() throws -> [RefusalRecord] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM refusal WHERE state = 'expired' ORDER BY id ASC")
                .map { try Self.refusalRecord(from: $0) }
        }
    }

    /// Every Refusal recorded for `feature`, oldest first.
    public func refusals(feature: FeatureName) throws -> [RefusalRecord] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM refusal WHERE feature_name = ? ORDER BY id ASC", arguments: [feature.rawValue]
            ).map { try Self.refusalRecord(from: $0) }
        }
    }

    private static func fetchRefusalRow(_ db: Database, id: Int64) throws -> Row {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM refusal WHERE id = ?", arguments: [id]) else {
            throw JournalError.refusalUnreadable(id: id)
        }
        return row
    }

    private static func refusalRecord(from row: Row) throws -> RefusalRecord {
        let id: Int64 = row["id"]
        let stateRaw: String = row["state"]
        guard let state = RefusalState(rawValue: stateRaw) else {
            throw JournalError.refusalUnreadable(id: id)
        }
        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.refusalUnreadable(id: id) }
        return RefusalRecord(
            id: id,
            featureName: row["feature_name"],
            issueID: row["issue_id"],
            state: state,
            content: row["content"],
            openedNightID: row["opened_night_id"],
            unansweredNights: row["unanswered_nights"],
            lastCountedNightID: row["last_counted_night_id"],
            consecutiveRefusals: row["consecutive_refusals"],
            expiredNightID: row["expired_night_id"],
            createdAt: createdAt
        )
    }
}
