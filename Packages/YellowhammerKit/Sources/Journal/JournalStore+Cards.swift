import Domain
import Foundation
import GRDB

// MARK: - Card Record

public enum WaitingReason: String, Sendable { case question, divergence }

public struct CardRecord: Equatable, Sendable {
    public let id: Int64
    public let cycleID: Int64
    public let issueID: String
    public let repository: String
    public let kind: String
    public let authoredOrder: Int
    public let state: CardState
    public let waitingReason: WaitingReason?
    public let blockReason: String?
    /// The state the Card held before the board said Cancelled; nil unless state is cancelled.
    public let cancelledFromState: CardState?
    /// Bumped by ``JournalStore/resetBudgetEpoch(cardID:reason:runID:act:nightID:now:)`` when an
    /// Override pinned in triage supersedes the exclusions an earlier epoch recorded
    /// (routing/exclude-tried-routes-on-retry, P7.7).
    public let budgetEpoch: Int
    public let createdAt: Date
    /// Bumped by every Journal-side state transition (``JournalStore/transitionCard(cardID:to:waitingReason:blockReason:runID:act:nightID:now:)``).
    public let stateVersion: Int
    /// The version of `stateVersion` last confirmed applied on the board; nil until the first confirmed write.
    public let boardStateVersion: Int?
    /// The unanswered-Nights clock (bounds/bound-unanswered-nights, roadmap P11.4): how many Nights this
    /// Card has been in Waiting on You without an answer, counted only across Nights an Act actually ran.
    public let unansweredNights: Int
    /// The Night this clock last counted, so a second Act of the same Night adds nothing; nil until the
    /// first advance after the Card most recently entered Waiting on You.
    public let unansweredLastCountedNightID: Int64?
    /// How many Adoptions this Card has failed consecutively (roadmap P11.5; spec: feature-authoring/
    /// author-the-cycle-and-card-dag, second story): reset to 0 by a clean Adoption. What
    /// `failed_adoptions_max` will read (roadmap P11.6) — this milestone only keeps the count.
    public let failedAdoptions: Int
}

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

    /// How many of one Cycle's Cards are unfinished. A Cancelled Card is not unfinished, which is
    /// what lets cancelling the last stuck Card release the Cycle to land.
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
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM card WHERE issue_id = ?",
                arguments: [issueID]
            )
            guard let row else { return nil }
            return try Self.cardRecord(from: row)
        }
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

        let rawCancelledFromState: String? = row["cancelled_from_state"]
        let cancelledFromState: CardState?
        if let rawCancelledFromState {
            guard let state = CardState(rawValue: rawCancelledFromState) else {
                throw JournalError.unknownCardState(cardID: id, state: rawCancelledFromState)
            }
            cancelledFromState = state
        } else {
            cancelledFromState = nil
        }

        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.cardUnreadable(id: id) }

        return CardRecord(
            id: id,
            cycleID: row["cycle_id"],
            issueID: row["issue_id"],
            repository: row["repository"],
            kind: row["kind"],
            authoredOrder: row["authored_order"],
            state: state,
            waitingReason: waitingReason,
            blockReason: row["block_reason"],
            cancelledFromState: cancelledFromState,
            budgetEpoch: row["budget_epoch"],
            createdAt: createdAt,
            stateVersion: row["state_version"],
            boardStateVersion: row["board_state_version"],
            unansweredNights: row["unanswered_nights"],
            unansweredLastCountedNightID: row["unanswered_last_counted_night_id"],
            failedAdoptions: row["failed_adoptions"]
        )
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

    /// The board read the Card as Cancelled. Sets state = Cancelled,
    /// cancelled_from_state = the previous state, appends `.cardCancelled` in the same
    /// write transaction, under the Act-scoped lease.
    /// Throws JournalError.cardAlreadyCancelled(cardID:) when it already is.
    @discardableResult
    public func markCardCancelled(
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

            // Check if already cancelled
            guard record.state != .cancelled else {
                throw JournalError.cardAlreadyCancelled(cardID: cardID)
            }

            // Update card: set state to Cancelled and cancelled_from_state to previous state
            try db.execute(
                sql: "UPDATE card SET state = ?, cancelled_from_state = ? WHERE id = ?",
                arguments: [CardState.cancelled.rawValue, record.state.rawValue, cardID]
            )

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)

            // The running agent is not interrupted (spec: "A Card cancelled while it is running") — but
            // any open Attempt this Card holds is not resumable state worth a budget, so it ends
            // `cancelled` in the same write: consumes no Attempt, excludes no Route, writes no
            // failure-cause row and touches no worktree, Feature Branch, round, budget_epoch or
            // block_reason.
            if let openRow = try Row.fetchOne(
                db, sql: "SELECT id FROM attempt WHERE card_id = ? AND ended_at IS NULL", arguments: [cardID]
            ) {
                let attemptID: Int64 = openRow["id"]
                let endedAt = JournalStore.stored(now)
                try db.execute(
                    sql: """
                    UPDATE attempt SET ended_at = ?, result = ?, classification = ?, consumed_how = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        JournalStore.timestamp(endedAt), AttemptEnding.cancelled.outcome.rawValue,
                        AttemptEnding.cancelled.classification, AttemptEnding.cancelled.consumedHow, attemptID
                    ]
                )
                guard let attempt = try Self.fetchAttempt(db, attemptID: attemptID) else {
                    throw JournalError.attemptUnknown(attemptID: attemptID)
                }
                let attemptEndedEvent = JournalEvent.attemptEnded(
                    cardID: cardID, issueID: record.issueID, attemptID: attemptID, route: attempt.route,
                    outcome: AttemptEnding.cancelled.outcome.rawValue, routeExcluded: false
                )
                _ = try Self.insertEvent(db, attemptEndedEvent, stamp: stamp)
            }

            // Append event
            let event = JournalEvent.cardCancelled(
                cardID: cardID,
                issueID: record.issueID,
                previousState: record.state
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)

            // Return updated record
            return try Self.cardRecord(from: row)
                .with(state: .cancelled, cancelledFromState: record.state)
        }
    }

    /// The board read a Journal-cancelled Card as reopened. Restores state from
    /// cancelled_from_state (or `todo` if that column is null), clears the column,
    /// appends `.cardReopened` in the same transaction, under the Act lease.
    /// Throws JournalError.cardNotCancelled(cardID:) when it is not cancelled.
    @discardableResult
    public func restoreCancelledCard(
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

            // Check if not cancelled
            guard record.state == .cancelled else {
                throw JournalError.cardNotCancelled(cardID: cardID)
            }

            // Determine restored state: use cancelled_from_state or default to todo
            let restoredState = record.cancelledFromState ?? .todo

            // Update card: set state to restored state and clear cancelled_from_state
            try db.execute(
                sql: "UPDATE card SET state = ?, cancelled_from_state = NULL WHERE id = ?",
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
                .with(state: restoredState, cancelledFromState: nil)
        }
    }
}

// MARK: - CardRecord helpers

extension CardRecord {
    fileprivate func with(state: CardState, cancelledFromState: CardState?) -> CardRecord {
        CardRecord(
            id: id,
            cycleID: cycleID,
            issueID: issueID,
            repository: repository,
            kind: kind,
            authoredOrder: authoredOrder,
            state: state,
            waitingReason: waitingReason,
            blockReason: blockReason,
            cancelledFromState: cancelledFromState,
            budgetEpoch: budgetEpoch,
            createdAt: createdAt,
            stateVersion: stateVersion,
            boardStateVersion: boardStateVersion,
            unansweredNights: unansweredNights,
            unansweredLastCountedNightID: unansweredLastCountedNightID,
            failedAdoptions: failedAdoptions
        )
    }
}
