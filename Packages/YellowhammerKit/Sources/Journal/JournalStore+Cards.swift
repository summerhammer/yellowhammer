import Domain
import Foundation
import GRDB

// The reads the Act trigger predicates are evaluated from. They answer two questions and no others:
// has this Project any Card left to work, and is there a Feature in flight whose Cycle is finished.
extension JournalStore {
    /// How many of this Project's Cards are unfinished, in any Cycle.
    ///
    /// Project-wide, because the author trigger asks about the Project rather than about one Cycle.
    public func unfinishedCardCount() throws -> Int {
        try read { db in
            try Self.countUnfinished(
                try Row.fetchAll(db, sql: "SELECT id, state FROM card")
            )
        }
    }

    /// The open Cycle's id, or nil when no Feature is in flight.
    ///
    /// A Cycle is open until it is archived, and an open Cycle is exactly what a Feature still in
    /// flight looks like in the Journal — which is why no Feature state is read here.
    public func inFlightCycleID() throws -> Int64? {
        try read { db in
            let cycleIDs = try Int64.fetchAll(db, sql: "SELECT id FROM cycle WHERE archived_at IS NULL")
            switch cycleIDs.count {
            case 0:
                return nil
            case 1:
                return cycleIDs[0]
            default:
                // A Project has one in-flight Feature, so it has one open Cycle. Two means the
                // Journal is inconsistent, and guessing which one is in flight would be worse.
                throw JournalError.multipleOpenCycles
            }
        }
    }

    /// How many of one Cycle's Cards are unfinished. A Shelved Card is not unfinished, which is
    /// what lets shelving the last stuck Card release the Cycle to land.
    public func unfinishedCardCount(cycleID: Int64) throws -> Int {
        try read { db in
            try Self.countUnfinished(
                try Row.fetchAll(db, sql: "SELECT id, state FROM card WHERE cycle_id = ?", arguments: [cycleID])
            )
        }
    }

    /// Counts the unfinished Cards among `rows`, refusing any whose state is outside the vocabulary.
    ///
    /// Only the engine writes `card.state`, so an unrecognised value means the Journal is
    /// inconsistent. It is counted neither way: treating it as finished would let the land Act fire
    /// over work nobody could classify, and treating it as unfinished would grind on a Card no Act
    /// can act on. The row is named instead, and every trigger for this Project stops.
    private static func countUnfinished(_ rows: [Row]) throws -> Int {
        try rows.reduce(into: 0) { count, row in
            let rawState: String = row["state"]
            guard let state = CardState(rawValue: rawState) else {
                throw JournalError.unknownCardState(cardID: row["id"], state: rawState)
            }
            if state.isUnfinished {
                count += 1
            }
        }
    }

    // MARK: - Card reads

    /// Every Card of this Project, ordered by id.
    public func cards() throws -> [CardRecord] {
        try read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM card ORDER BY id ASC")
            return try rows.map { row in
                try Self.cardRecord(from: row)
            }
        }
    }

    /// A Card by its issue id, or nil if not found.
    public func card(issueID: String) throws -> CardRecord? {
        try read { db in
            try Self.card(db, issueID: issueID)
        }
    }

    /// Internal: same read as ``card(issueID:)``, over a `Database` a caller already holds open — so a
    /// multi-table read (e.g. ``cardAccount(issueID:)``) can share one transaction with it.
    static func card(_ db: Database, issueID: String) throws -> CardRecord? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM card WHERE issue_id = ?",
            arguments: [issueID]
        )
        guard let row else { return nil }
        return try Self.cardRecord(from: row)
    }

    /// A Card by its Journal id. Throws JournalError.cardUnknown if not found.
    public func card(id: Int64) throws -> CardRecord {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [id]) else {
                throw JournalError.cardUnknown(cardID: id)
            }
            return try Self.cardRecord(from: row)
        }
    }

    static func cardRecord(from row: Row) throws -> CardRecord {
        let id: Int64 = row["id"]
        let rawState: String = row["state"]
        guard let state = CardState(rawValue: rawState) else {
            throw JournalError.unknownCardState(cardID: id, state: rawState)
        }

        let rawWaitingReason: String? = row["waiting_reason"]
        let waitingReason = rawWaitingReason.flatMap { WaitingReason(rawValue: $0) }

        let rawShelvedFromState: String? = row["shelved_from_state"]
        let shelvedFromState: CardState?
        if let rawShelvedFromState {
            guard let state = CardState(rawValue: rawShelvedFromState) else {
                throw JournalError.unknownCardState(cardID: id, state: rawShelvedFromState)
            }
            shelvedFromState = state
        } else {
            shelvedFromState = nil
        }

        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.cardUnreadable(id: id) }

        return CardRecord(
            id: id,
            cycleID: row["cycle_id"],
            issueID: row["issue_id"],
            issueIDForDisplay: row["issue_id_for_display"] ?? row["issue_key"],
            title: row["title"],
            repository: row["repository"],
            kind: row["kind"],
            authoredOrder: row["authored_order"],
            state: state,
            waitingReason: waitingReason,
            blockReason: row["block_reason"],
            shelvedFromState: shelvedFromState,
            budgetEpoch: row["budget_epoch"],
            createdAt: createdAt,
            stateVersion: row["state_version"],
            boardStateVersion: row["board_state_version"],
            unansweredNights: row["unanswered_nights"],
            unansweredLastCountedNightID: row["unanswered_last_counted_night_id"],
            failedAdoptions: row["failed_adoptions"],
            divergenceStandingNightID: row["divergence_standing_night_id"],
            issueKey: row["issue_key"],
            issueURL: row["issue_url"],
            removedFromBoard: try removal(cardID: id, raw: row["removed_from_board"])
        )
    }

    private static func removal(cardID: Int64, raw: String?) throws -> CardRemoval? {
        guard let raw else { return nil }
        guard let removal = CardRemoval(rawValue: raw) else {
            throw JournalError.cardUnreadable(id: cardID)
        }
        return removal
    }

    /// Every Card of this Cycle that is a hole in the Feature (graph-execution/handle-a-block-mid-graph,
    /// P8.9): Blocked or Waiting on You, sorted by repository then authored order, so the Partial
    /// Landing announcement (P10.4) can name them in a stable, readable order.
    public func laneHoles(cycleID: Int64) throws -> [CardRecord] {
        try cards(cycleID: cycleID).filter { $0.state == .blocked || $0.state == .waitingOnYou }
            .sorted { lhs, rhs in
                lhs.repository == rhs.repository
                    ? lhs.authoredOrder < rhs.authoredOrder
                    : lhs.repository < rhs.repository
            }
    }

    // MARK: - Card state changes

    /// The board read the Card as Shelved. Sets state = Shelved,
    /// shelved_from_state = the previous state, appends `.cardShelved` in the same
    /// write transaction, under the Act-scoped lease.
    /// Throws JournalError.cardAlreadyShelved(cardID:) when it already is.
    @discardableResult
    public func markCardShelved(
        cardID: Int64,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            // Revalidate Act lease
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            // Fetch the Card
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }

            let record = try Self.cardRecord(from: row)

            // Check if already shelved
            guard record.state != .shelved else {
                throw JournalError.cardAlreadyShelved(cardID: cardID)
            }

            // Update card: set state to Shelved and shelved_from_state to previous state
            try db.execute(
                sql: "UPDATE card SET state = ?, shelved_from_state = ? WHERE id = ?",
                arguments: [CardState.shelved.rawValue, record.state.rawValue, cardID]
            )

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)

            // The running agent is not interrupted (spec: "A Card shelved while it is running"), but any
            // open Attempt ends `cancelled` in the same write.
            try Self.cancelOpenAttempt(db, cardID: cardID, issueID: record.issueID, stamp: stamp)

            // Append event
            let event = JournalEvent.cardShelved(
                cardID: cardID,
                issueID: record.issueID,
                previousState: record.state
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)

            // Return updated record
            return try Self.cardRecord(from: row)
                .with(state: .shelved, shelvedFromState: record.state)
        }
    }

    /// The board read a Journal-shelved Card as reopened. Restores state from
    /// shelved_from_state (or `todo` if that column is null), clears the column,
    /// appends `.cardReopened` in the same transaction, under the Act lease.
    /// Throws JournalError.cardNotShelved(cardID:) when it is not shelved.
    @discardableResult
    public func restoreShelvedCard(
        cardID: Int64,
        runID: RunID,
        act: Act?,
        nightID: Int64?,
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            // Revalidate Act lease
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            // Fetch the Card
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }

            let record = try Self.cardRecord(from: row)

            // Check if not shelved
            guard record.state == .shelved else {
                throw JournalError.cardNotShelved(cardID: cardID)
            }

            // Determine restored state: use shelved_from_state or default to todo
            let restoredState = record.shelvedFromState ?? .todo

            // Update card: set state to restored state and clear shelved_from_state
            try db.execute(
                sql: "UPDATE card SET state = ?, shelved_from_state = NULL WHERE id = ?",
                arguments: [restoredState.rawValue, cardID]
            )

            // Append event
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            let event = JournalEvent.cardReopened(
                cardID: cardID,
                issueID: record.issueID,
                restoredState: restoredState
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)

            // Return updated record
            return try Self.cardRecord(from: row)
                .with(state: restoredState, shelvedFromState: nil)
        }
    }

    /// Ends the Card's open Attempt, if any, `cancelled`: it is not resumable state worth a budget, so it
    /// consumes no Attempt, excludes no Route, writes no failure-cause row and touches no worktree,
    /// Feature Branch, round, budget_epoch or block_reason. Shared by Shelve and removal from the board
    /// (OQ142), which both set a Card aside without interrupting a running agent.
    static func cancelOpenAttempt(_ db: Database, cardID: Int64, issueID: String, stamp: EventStamp) throws {
        guard let openRow = try Row.fetchOne(
            db, sql: "SELECT id FROM attempt WHERE card_id = ? AND ended_at IS NULL", arguments: [cardID]
        ) else { return }
        let attemptID: Int64 = openRow["id"]
        try db.execute(
            sql: """
            UPDATE attempt SET ended_at = ?, result = ?, classification = ?, consumed_how = ?
            WHERE id = ?
            """,
            arguments: [
                JournalStore.timestamp(JournalStore.stored(stamp.now)), AttemptEnding.cancelled.outcome.rawValue,
                AttemptEnding.cancelled.classification, AttemptEnding.cancelled.consumedHow, attemptID
            ]
        )
        guard let attempt = try Self.fetchAttempt(db, attemptID: attemptID) else {
            throw JournalError.attemptUnknown(attemptID: attemptID)
        }
        _ = try Self.insertEvent(db, .attemptEnded(
            cardID: cardID, issueID: issueID, attemptID: attemptID, route: attempt.route,
            outcome: AttemptEnding.cancelled.outcome.rawValue, routeExcluded: false
        ), stamp: stamp)
    }
}
