import Domain
import Foundation
import GRDB

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

    /// One Attempt after another in the same budget epoch, and whether it landed on a Route no
    /// earlier Attempt in that epoch had tried (routing/exclude-tried-routes-on-retry; reported by
    /// the Night Summary).
    public struct Retry: Equatable, Sendable {
        public let attemptID: Int64
        public let route: Route
        public let differentRoute: Bool
    }

    /// Every Attempt after the first of its budget epoch, in `attempt.id` order.
    public var retries: [Retry] {
        var seenByEpoch: [Int: Set<Route>] = [:]
        var retries: [Retry] = []
        for attempt in attempts {
            var seen = seenByEpoch[attempt.budgetEpoch] ?? []
            if !seen.isEmpty {
                retries.append(
                    Retry(attemptID: attempt.id, route: attempt.route, differentRoute: !seen.contains(attempt.route))
                )
            }
            seen.insert(attempt.route)
            seenByEpoch[attempt.budgetEpoch] = seen
        }
        return retries
    }

    /// The Block Reason for `epoch`, derived from a single source (Attempt, Block and Reset Ruling
    /// 2026-09-19, OQ58): the epoch's last ENDED, consuming Attempt — a `question` or `cancelled` ending
    /// is skipped, and so is any still-open Attempt. An `aborted` one is NOT (unlike in
    /// ``consumption(inEpoch:)``): as the last, the Card blocks `operator abort`. `rounds-exhausted` blocks by that Attempt's last Round's Lens;
    /// a hard failure blocks `hard failure`; a Crashed-Unknown blocks `host crash`, or `engine stop` when
    /// its run recorded that the engine stopped it (OQ92); no such Attempt at all blocks `hard failure`.
    /// Every Block path — budget spent, found already spent, or a Route exclusion leaving none — reads this.
    public func blockReason(inEpoch epoch: Int) -> BlockReason {
        guard let last = attempts.last(where: {
            $0.budgetEpoch == epoch && $0.endedAt != nil
                && $0.result != AttemptOutcome.question.rawValue
                && $0.result != AttemptOutcome.cancelled.rawValue
        }) else {
            return .hardFailure
        }
        switch last.result {
        case AttemptOutcome.roundsExhausted.rawValue:
            guard let lens = last.rounds.last?.lens else { return .hardFailure }
            return lens == .check ? .blockedByCheck : .blockedByReviewer
        case AttemptOutcome.crashedUnknown.rawValue:
            return last.classification?.hasPrefix(AttemptEnding.engineStoppedClassificationPrefix) == true
                ? .engineStop : .hostCrash
        case AttemptOutcome.aborted.rawValue: return .operatorAbort
        default:
            return .hardFailure
        }
    }

    /// How many of one budget epoch's Attempts consumed the Attempt budget, and by what — the single
    /// source both the Attempt budget arithmetic (``CardRun``) and the Attempt budget guard (P8.7) read,
    /// so "how many are consumed" and "why" are never counted two different ways. Split into
    /// `AttemptConsumption.swift` to keep this file under the length limit.
    public func consumption(inEpoch epoch: Int) -> AttemptConsumption {
        let ofEpoch = attempts.filter { $0.budgetEpoch == epoch }
        // An open Attempt (`result == nil`) counts as consumed: the row is written at dispatch precisely
        // so an unclassified Attempt still binds the Bound. `question`, `cancelled` and `aborted` consume
        // nothing: no resumable state to protect a budget for, and an abort is not the Route's failure.
        let nonConsuming = [AttemptOutcome.question, .cancelled, .aborted].map(\.rawValue)
        let consumed = ofEpoch.filter { !nonConsuming.contains($0.result ?? "") }
        func count(_ outcome: AttemptOutcome) -> Int {
            ofEpoch.filter { $0.result == outcome.rawValue }.count
        }
        return AttemptConsumption(
            consumed: consumed.count,
            routesFailed: count(.hardFailure),
            roundsExhausted: count(.roundsExhausted),
            crashedUnknown: count(.crashedUnknown),
            succeeded: count(.success),
            notConsumed: count(.question) + count(.cancelled) + count(.aborted)
        )
    }
}

extension JournalStore {
    /// Records a new Attempt: one dispatch of `cardID` to `route`. One write transaction, revalidating
    /// the Act-scoped lease before writing, exactly as every Journal write does. The Card's current
    /// `budget_epoch` is copied onto the Attempt at the moment it starts.
    ///
    /// When the Card already has at least one Attempt in the same budget epoch, this Attempt is a
    /// retry: `.routeRetried` is appended in the same transaction, `differentRoute` true iff `route`
    /// differs from every Route of the epoch's earlier Attempts (routing/exclude-tried-routes-on-retry,
    /// P7.7). The first Attempt of an epoch appends nothing.
    @discardableResult
    public func recordAttempt(
        cardID: Int64,
        route: Route,
        checkDeclaredNone: Bool = false,
        routeSource: String? = nil,
        override: Override? = nil,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        now: Date = Date()
    ) throws -> AttemptRecord {
        let overridePin = override?.description
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            let (budgetEpoch, issueID) = try Self.beginAttempt(db, cardID: cardID)
            let priorRoutes = try Self.routesTried(db, cardID: cardID, budgetEpoch: budgetEpoch)

            let startedAt = JournalStore.stored(now)
            try db.execute(
                sql: """
                INSERT INTO attempt (
                    card_id, budget_epoch, route_cli, route_model, route_effort, check_declared_none,
                    route_source, override_pin, started_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cardID, budgetEpoch, route.cli, route.model, route.effort, checkDeclaredNone ? 1 : 0,
                    routeSource, overridePin, JournalStore.timestamp(startedAt)
                ]
            )
            let attemptID = db.lastInsertedRowID

            if !priorRoutes.isEmpty {
                let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
                let event = JournalEvent.routeRetried(
                    cardID: cardID, issueID: issueID, attemptID: attemptID, route: route,
                    differentRoute: !priorRoutes.contains(route)
                )
                _ = try Self.insertEvent(db, event, stamp: stamp)
            }

            return AttemptRecord(
                id: attemptID,
                cardID: cardID,
                budgetEpoch: budgetEpoch,
                route: route,
                classification: nil,
                result: nil,
                consumedHow: nil,
                checkDeclaredNone: checkDeclaredNone,
                routeSource: routeSource,
                overridePin: overridePin,
                startedAt: startedAt,
                endedAt: nil,
                rounds: [],
                preservedRef: nil,
                preservedCommit: nil
            )
        }
    }

    /// The Card's current budget epoch and issue id, read fresh inside the caller's write transaction.
    /// Throws `cardUnknown` when the Card does not exist, `attemptStillOpen` when it already has an open
    /// Attempt — a Card is dispatched once at a time.
    private static func beginAttempt(_ db: Database, cardID: Int64) throws -> (budgetEpoch: Int, issueID: String) {
        guard let cardRow = try Row.fetchOne(
            db, sql: "SELECT budget_epoch, issue_id FROM card WHERE id = ?", arguments: [cardID]
        ) else {
            throw JournalError.cardUnknown(cardID: cardID)
        }
        if let openRow = try Row.fetchOne(
            db, sql: "SELECT id FROM attempt WHERE card_id = ? AND ended_at IS NULL", arguments: [cardID]
        ) {
            throw JournalError.attemptStillOpen(cardID: cardID, attemptID: openRow["id"])
        }
        return (cardRow["budget_epoch"], cardRow["issue_id"])
    }

    /// Every Route an Attempt of `cardID` has already run on in `budgetEpoch`, read fresh inside the
    /// caller's write transaction.
    private static func routesTried(_ db: Database, cardID: Int64, budgetEpoch: Int) throws -> Set<Route> {
        try Set(
            Row.fetchAll(
                db,
                sql: "SELECT route_cli, route_model, route_effort FROM attempt WHERE card_id = ? AND budget_epoch = ?",
                arguments: [cardID, budgetEpoch]
            ).compactMap { row in
                Route(cli: row["route_cli"], model: row["route_model"], effort: row["route_effort"])
            }
        )
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
    /// ``JournalStore/endAttempt(attemptID:ending:runID:act:nightID:now:)`` is the engine's path: it
    /// carries the typed vocabulary and writes the route-exclusion consequence this overload does not.
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
        try read { db in try Self.attemptHistory(db, cardID: cardID) }
    }

    /// Internal: same read as ``attemptHistory(cardID:)``, over a `Database` a caller already holds open.
    static func attemptHistory(_ db: Database, cardID: Int64) throws -> AttemptHistory {
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

    /// Throws unless `attemptID` exists and is open.
    static func requireOpenAttempt(_ db: Database, attemptID: Int64) throws {
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
    static func fetchAttempt(_ db: Database, attemptID: Int64) throws -> AttemptRecord? {
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
            routeSource: row["route_source"],
            overridePin: row["override_pin"],
            startedAt: try JournalStore.date(row["started_at"], onError: onError),
            endedAt: endedAt,
            rounds: rounds,
            preservedRef: row["preserved_ref"],
            preservedCommit: row["preserved_commit"]
        )
    }
}
