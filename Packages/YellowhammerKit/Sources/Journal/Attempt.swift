import Domain
import Foundation
import GRDB

/// One judgement pass over an Attempt's work, from a Lens (`review` or `check`), with its verdict, any
/// requested changes, and the commit it judged.
public struct RoundRecord: Equatable, Sendable {
    public let id: Int64
    public let attemptID: Int64
    public let lens: Lens
    public let verdict: String
    public let requestedChanges: String?
    public let judgedCommit: String?
    public let createdAt: Date
}

/// One dispatch of a Card to a Route, with the Rounds judged over its work. An open Attempt (`endedAt`
/// is `nil`) with no live run behind it is what a killed invocation leaves: classifying it
/// (Crashed-Unknown or otherwise) is a later phase's work, so this record only reports it.
public struct AttemptRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    public let budgetEpoch: Int
    public let route: Route
    public let classification: String?
    public let result: String?
    public let consumedHow: String?
    public let checkDeclaredNone: Bool
    public let startedAt: Date
    public let endedAt: Date?
    public let rounds: [RoundRecord]

    /// Whether this Attempt has not yet ended. By invariant, a Card has at most one open Attempt.
    public var isOpen: Bool { endedAt == nil }
}

/// A Card's whole Attempt and Round history, rebuilt from the `attempt`, `round` and `route_exclusion`
/// rows alone: nothing about a Card's dispatches lives anywhere else. A resumed Act reconstructs
/// Attempt and Round counts and routes tried entirely from this.
public struct AttemptHistory: Equatable, Sendable {
    public let cardID: Int64
    /// In `attempt.id` order, each with its Rounds in `round.id` order.
    public let attempts: [AttemptRecord]
    /// From `route_exclusion`, ordered by `excluded_at` then Route.
    public let excludedRoutes: [Route]

    public var attemptCount: Int { attempts.count }
    public var roundCount: Int { attempts.reduce(0) { $0 + $1.rounds.count } }

    /// Distinct Routes tried, in the order they were first tried.
    public var routesTried: [Route] {
        var seen: Set<Route> = []
        var ordered: [Route] = []
        for attempt in attempts where !seen.contains(attempt.route) {
            seen.insert(attempt.route)
            ordered.append(attempt.route)
        }
        return ordered
    }

    /// The Attempt with no `endedAt`, if any. By invariant, a Card has at most one.
    public var openAttempt: AttemptRecord? {
        attempts.first { $0.isOpen }
    }
}

extension JournalStore {
    /// Records a new Attempt: one dispatch of `cardID` to `route`. One write transaction, revalidating
    /// the Act-scoped lease before writing, exactly as every Journal write does. The Card's current
    /// `budget_epoch` is copied onto the Attempt at the moment it starts.
    @discardableResult
    public func recordAttempt(
        cardID: Int64,
        route: Route,
        checkDeclaredNone: Bool = false,
        runID: RunID,
        now: Date = Date()
    ) throws -> AttemptRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let budgetEpoch = try Int.fetchOne(
                db, sql: "SELECT budget_epoch FROM card WHERE id = ?", arguments: [cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }

            if let openRow = try Row.fetchOne(
                db, sql: "SELECT id FROM attempt WHERE card_id = ? AND ended_at IS NULL", arguments: [cardID]
            ) {
                throw JournalError.attemptStillOpen(cardID: cardID, attemptID: openRow["id"])
            }

            let startedAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                INSERT INTO attempt (card_id, budget_epoch, route_cli, route_model, route_effort, \
                check_declared_none, started_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cardID, budgetEpoch, route.cli, route.model, route.effort, checkDeclaredNone ? 1 : 0,
                    JournalStore.timestamp(startedAt)
                ]
            )
            let attemptID = db.lastInsertedRowID

            return AttemptRecord(
                id: attemptID,
                cardID: cardID,
                budgetEpoch: budgetEpoch,
                route: route,
                classification: nil,
                result: nil,
                consumedHow: nil,
                checkDeclaredNone: checkDeclaredNone,
                startedAt: startedAt,
                endedAt: nil,
                rounds: []
            )
        }
    }

    /// Records a Round of judgement over `attemptID`'s work. One write transaction, revalidating the
    /// Act-scoped lease before writing.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public func recordRound(
        attemptID: Int64,
        lens: Lens,
        verdict: String,
        requestedChanges: String?,
        judgedCommit: String?,
        runID: RunID,
        now: Date = Date()
    ) throws -> RoundRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            try Self.requireOpenAttempt(db, attemptID: attemptID)

            let createdAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                INSERT INTO round (attempt_id, lens, verdict, requested_changes, judged_commit, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    attemptID, lens.rawValue, verdict, requestedChanges, judgedCommit, JournalStore.timestamp(createdAt)
                ]
            )
            let roundID = db.lastInsertedRowID

            return RoundRecord(
                id: roundID,
                attemptID: attemptID,
                lens: lens,
                verdict: verdict,
                requestedChanges: requestedChanges,
                judgedCommit: judgedCommit,
                createdAt: createdAt
            )
        }
    }

    /// Ends `attemptID` with a `result`. `result`, `classification` and `consumedHow` stay plain
    /// strings here: their vocabularies belong to a later phase, so this only stores what it is given.
    @discardableResult
    public func endAttempt(
        attemptID: Int64,
        result: String,
        classification: String? = nil,
        consumedHow: String? = nil,
        runID: RunID,
        now: Date = Date()
    ) throws -> AttemptRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            try Self.requireOpenAttempt(db, attemptID: attemptID)

            let endedAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                UPDATE attempt SET ended_at = ?, result = ?, classification = ?, consumed_how = ?
                WHERE id = ?
                """,
                arguments: [JournalStore.timestamp(endedAt), result, classification, consumedHow, attemptID]
            )

            guard let record = try Self.fetchAttempt(db, attemptID: attemptID) else {
                throw JournalError.attemptUnknown(attemptID: attemptID)
            }
            return record
        }
    }

    /// A Card's whole Attempt and Round history, rebuilt from the Journal's rows alone.
    public func attemptHistory(cardID: Int64) throws -> AttemptHistory {
        try read { db in
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM card WHERE id = ?", arguments: [cardID]) != nil else {
                throw JournalError.cardUnknown(cardID: cardID)
            }

            let attemptRows = try Row.fetchAll(
                db, sql: "SELECT id FROM attempt WHERE card_id = ? ORDER BY id ASC", arguments: [cardID]
            )
            let attempts = try attemptRows.map { row -> AttemptRecord in
                let attemptID: Int64 = row["id"]
                guard let record = try Self.fetchAttempt(db, attemptID: attemptID) else {
                    throw JournalError.attemptUnreadable(id: attemptID)
                }
                return record
            }

            let exclusionRows = try Row.fetchAll(
                db,
                sql: """
                SELECT route_cli, route_model, route_effort FROM route_exclusion
                WHERE card_id = ? ORDER BY excluded_at ASC, route_cli ASC, route_model ASC, route_effort ASC
                """,
                arguments: [cardID]
            )
            let excludedRoutes: [Route] = try exclusionRows.map { row in
                guard let route = Route(
                    cli: row["route_cli"], model: row["route_model"], effort: row["route_effort"]
                ) else {
                    throw JournalError.routeExclusionUnreadable(cardID: cardID)
                }
                return route
            }

            return AttemptHistory(cardID: cardID, attempts: attempts, excludedRoutes: excludedRoutes)
        }
    }

    /// Throws unless `attemptID` exists and is open.
    private static func requireOpenAttempt(_ db: Database, attemptID: Int64) throws {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT ended_at FROM attempt WHERE id = ?", arguments: [attemptID]
        ) else {
            throw JournalError.attemptUnknown(attemptID: attemptID)
        }
        let endedAt: String? = row["ended_at"]
        guard endedAt == nil else {
            throw JournalError.attemptEnded(attemptID: attemptID)
        }
    }

    /// Fetches one Attempt with its Rounds, in `round.id` order. `nil` if it does not exist.
    private static func fetchAttempt(_ db: Database, attemptID: Int64) throws -> AttemptRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM attempt WHERE id = ?", arguments: [attemptID])
        else {
            return nil
        }

        let onError = { JournalError.attemptUnreadable(id: attemptID) }
        guard let route = Route(
            cli: row["route_cli"], model: row["route_model"], effort: row["route_effort"]
        ) else {
            throw onError()
        }

        let endedAtText: String? = row["ended_at"]
        let endedAt = try endedAtText.map { try JournalStore.date($0, onError: onError) }

        let roundRows = try Row.fetchAll(
            db, sql: "SELECT * FROM round WHERE attempt_id = ? ORDER BY id ASC", arguments: [attemptID]
        )
        let rounds = try roundRows.map { roundRow -> RoundRecord in
            let roundID: Int64 = roundRow["id"]
            let roundOnError = { JournalError.roundUnreadable(id: roundID) }
            guard let lens = Lens(rawValue: roundRow["lens"]) else {
                throw roundOnError()
            }
            return RoundRecord(
                id: roundID,
                attemptID: attemptID,
                lens: lens,
                verdict: roundRow["verdict"],
                requestedChanges: roundRow["requested_changes"],
                judgedCommit: roundRow["judged_commit"],
                createdAt: try JournalStore.date(roundRow["created_at"], onError: roundOnError)
            )
        }

        return AttemptRecord(
            id: attemptID,
            cardID: row["card_id"],
            budgetEpoch: row["budget_epoch"],
            route: route,
            classification: row["classification"],
            result: row["result"],
            consumedHow: row["consumed_how"],
            checkDeclaredNone: ((row["check_declared_none"] as Int?) ?? 0) != 0,
            startedAt: try JournalStore.date(row["started_at"], onError: onError),
            endedAt: endedAt,
            rounds: rounds
        )
    }
}
