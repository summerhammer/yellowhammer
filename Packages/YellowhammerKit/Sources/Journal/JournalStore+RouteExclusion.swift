import Domain
import Foundation
import GRDB

// The read route resolution filters by (routing/resolve-a-route-for-a-card, P7.6), and the writes
// that produce the rows it reads: an Attempt ending in a capability failure excludes its Route, and
// an Override pinned in triage resets the epoch so an earlier epoch's exclusions stop applying
// (routing/exclude-tried-routes-on-retry, P7.7).

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

    /// Ends `attemptID` with the typed ``AttemptEnding`` vocabulary: the engine's path, over
    /// ``endAttempt(attemptID:result:classification:consumedHow:runID:now:)``. One write transaction:
    /// revalidates the Act-scoped lease, requires the Attempt open, updates `result`, `classification`
    /// and `consumed_how` from `ending`, and — when `ending.excludesRoute` — inserts (or, on a second
    /// capability failure of the same Route in this epoch, leaves alone) the `route_exclusion` row for
    /// the Attempt's own `budget_epoch` and Route. Appends `.attemptEnded` in the same transaction.
    @discardableResult
    public func endAttempt(
        attemptID: Int64,
        ending: AttemptEnding,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        now: Date = Date()
    ) throws -> AttemptRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            try Self.requireOpenAttempt(db, attemptID: attemptID)

            guard let before = try Self.fetchAttempt(db, attemptID: attemptID) else {
                throw JournalError.attemptUnknown(attemptID: attemptID)
            }

            let endedAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                UPDATE attempt SET ended_at = ?, result = ?, classification = ?, consumed_how = ?
                WHERE id = ?
                """,
                arguments: [
                    JournalStore.timestamp(endedAt), ending.outcome.rawValue, ending.classification,
                    ending.consumedHow, attemptID
                ]
            )

            if ending.excludesRoute, let reason = ending.exclusionReason {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO route_exclusion
                    (card_id, budget_epoch, route_cli, route_model, route_effort, reason, excluded_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        before.cardID, before.budgetEpoch, before.route.cli, before.route.model,
                        before.route.effort, reason, JournalStore.timestamp(endedAt)
                    ]
                )
            }

            guard let cardRow = try Row.fetchOne(
                db, sql: "SELECT issue_id FROM card WHERE id = ?", arguments: [before.cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: before.cardID)
            }
            let issueID: String = cardRow["issue_id"]

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            let event = JournalEvent.attemptEnded(
                cardID: before.cardID, issueID: issueID, attemptID: attemptID, route: before.route,
                outcome: ending.outcome.rawValue, routeExcluded: ending.excludesRoute
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)

            guard let record = try Self.fetchAttempt(db, attemptID: attemptID) else {
                throw JournalError.attemptUnknown(attemptID: attemptID)
            }
            return record
        }
    }

    /// An Override pinned in triage supersedes an earlier epoch's exclusions: bumps `card.budget_epoch`
    /// by one, so ``excludedRoutes(cardID:)`` no longer returns what the old epoch excluded, and
    /// appends `.budgetEpochReset` in the same write transaction. Revalidates the Act-scoped lease, and
    /// refuses with ``JournalError/attemptStillOpen(cardID:attemptID:)`` while the Card has an open
    /// Attempt — a Card is dispatched once at a time, and a reset mid-dispatch would orphan it.
    @discardableResult
    public func resetBudgetEpoch(
        cardID: Int64,
        reason: String,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let record = try Self.cardRecord(from: row)

            try Self.resetBudgetEpoch(
                db, record: record, reason: reason,
                stamp: EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            )

            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            return try Self.cardRecord(from: updated)
        }
    }

    /// Shared by explicit epoch resets and state transitions so re-ready commits both atomically.
    static func resetBudgetEpoch(
        _ db: Database, record: CardRecord, reason: String, stamp: EventStamp
    ) throws {
        if let openRow = try Row.fetchOne(
            db, sql: "SELECT id FROM attempt WHERE card_id = ? AND ended_at IS NULL", arguments: [record.id]
        ) {
            throw JournalError.attemptStillOpen(cardID: record.id, attemptID: openRow["id"])
        }

        let from = record.budgetEpoch
        let to = from + 1
        try db.execute(sql: "UPDATE card SET budget_epoch = ? WHERE id = ?", arguments: [to, record.id])

        let event = JournalEvent.budgetEpochReset(
            cardID: record.id, issueID: record.issueID, from: from, to: to, reason: reason
        )
        _ = try Self.insertEvent(db, event, stamp: stamp)
    }
}
