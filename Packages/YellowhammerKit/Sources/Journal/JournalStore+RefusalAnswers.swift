import Domain
import Foundation
import GRDB

// How a Refusal leaves the clock (roadmap P9.7, P9.8; glossary: Refusal): a Spec Citation answers it; a
// clean authoring run merely closes it. Split out of JournalStore+Refusals.swift for the file length limit.

/// What `answerRefusal` did: the Refusal now `answered`, and the state it was in.
public struct RefusalAnswerOutcome: Equatable, Sendable {
    public let record: RefusalRecord
    /// `open` or `expired`.
    public let previousState: RefusalState
}

extension JournalStore {
    /// A clean authoring run for `feature` resets its consecutive-refusals count to zero on every one
    /// of its rows, and closes its `answered` and `open` rows (`closed_night_id`) so they leave the
    /// clock — never touching another Feature's rows. It never writes `answered` itself, and leaves an
    /// `expired` row's state and closure alone: only a Spec Citation answers a Refusal
    /// (``answerRefusal(feature:citation:nightID:act:runID:now:)``). Appends `refusalCountReset` only
    /// when there was something to change; returns whether it did.
    @discardableResult
    public func resetConsecutiveRefusals(
        feature: FeatureName, nightID: Int64? = nil, act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> Bool {
        try write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, state, consecutive_refusals, closed_night_id FROM refusal WHERE feature_name = ?",
                arguments: [feature.rawValue]
            )
            var changed = false
            for row in rows {
                let id: Int64 = row["id"]
                let state: String = row["state"]
                let count: Int = row["consecutive_refusals"]
                let closedNight: Int64? = row["closed_night_id"]
                if count != 0 {
                    try db.execute(sql: "UPDATE refusal SET consecutive_refusals = 0 WHERE id = ?", arguments: [id])
                    changed = true
                }
                let closable = state == RefusalState.open.rawValue || state == RefusalState.answered.rawValue
                if closable, closedNight == nil, let nightID {
                    try db.execute(sql: "UPDATE refusal SET closed_night_id = ? WHERE id = ?", arguments: [nightID, id])
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

    /// A Spec Citation answers `feature`'s latest live Refusal, `open` or `expired`, to `answered`
    /// (glossary: Refusal). Appends `refusalAnswered` naming the state it left. The consecutive count is
    /// untouched. Returns nil, changing nothing, when there is no live `open` or `expired` Refusal —
    /// `standing_item`, already `answered` and closed rows are not answerable.
    @discardableResult
    public func answerRefusal(
        feature: FeatureName, citation: String, nightID: Int64? = nil, act: Act? = nil, runID: RunID? = nil,
        now: Date = Date()
    ) throws -> RefusalAnswerOutcome? {
        try write { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM refusal
                    WHERE feature_name = ? AND closed_night_id IS NULL AND state IN ('open','expired')
                    ORDER BY id DESC LIMIT 1
                    """,
                    arguments: [feature.rawValue]
                )
            else {
                return nil
            }
            let id: Int64 = row["id"]
            let previous: String = row["state"]
            guard let previousState = RefusalState(rawValue: previous) else {
                throw JournalError.refusalUnreadable(id: id)
            }
            try db.execute(sql: "UPDATE refusal SET state = 'answered' WHERE id = ?", arguments: [id])
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
            _ = try Self.insertEvent(
                db, .refusalAnswered(feature: feature.rawValue, citation: citation, from: previous), stamp: stamp
            )
            let record = try Self.refusalRecord(from: try Self.fetchRefusalRow(db, id: id))
            return RefusalAnswerOutcome(record: record, previousState: previousState)
        }
    }
}
