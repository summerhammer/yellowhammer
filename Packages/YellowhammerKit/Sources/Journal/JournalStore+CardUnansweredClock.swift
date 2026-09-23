import Domain
import Foundation
import GRDB

// The Card side of the unanswered-Nights clock (roadmap P11.4; spec: bounds/bound-unanswered-nights):
// mirrors the Refusal and Authoring Halt clocks (JournalStore+Refusals.swift,
// JournalStore+AuthoringHalts.swift), but counted per Card rather than per Feature, and only across the
// Cycles this call names (a Project's Cards, never a sibling Project's). A banked reply halts the clock
// exactly as an unbanked one does — an answer already read is not silence — so a Card with a banked
// reply is excluded from the advance entirely, the same way the author Act already checks before
// spending a Delta Read (``JournalStore/hasWaitingOnYouCardInLandedCycle()``).

extension JournalStore {
    /// Advances one Night's worth of the unanswered-Nights clock for every Card, in `cycleIDs`, that is
    /// currently Waiting on You, has no banked reply, and has not already been counted for `nightID`
    /// (idempotent within a Night across Acts — an author and a build Act of the same Night, or two Acts
    /// of either kind, count once). One write transaction under the Act-scoped Lease.
    ///
    /// A Card whose new count first exceeds `unansweredNightsMax` appends `.cardUnansweredBoundFired`
    /// with the Block Reason its `waitingReason` implies (`unanswered` for `question`, `undecided` for
    /// `divergence`) — this call only records that the bound fired; ``cardsPastUnansweredBound(cycleIDs:unansweredNightsMax:)``
    /// is what the engine actually blocks from, so an Act killed between this call and the board write
    /// is completed by the next Act rather than silently losing the block.
    @discardableResult
    public func advanceCardUnansweredClocks(
        cycleIDs: [Int64], nightID: Int64, unansweredNightsMax: Int, act: Act? = nil, runID: RunID,
        now: Date = Date()
    ) throws -> [CardRecord] {
        guard !cycleIDs.isEmpty else { return [] }
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))

            let placeholders = cycleIDs.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT card.* FROM card
                WHERE card.cycle_id IN (\(placeholders)) AND card.state = ?
                  AND (card.unanswered_last_counted_night_id IS NULL
                       OR card.unanswered_last_counted_night_id != ?)
                  AND NOT EXISTS (
                    SELECT 1 FROM card_reply
                    JOIN banked_reply ON banked_reply.comment_id = card_reply.comment_id
                    WHERE card_reply.card_id = card.id
                  )
                """,
                arguments: StatementArguments(cycleIDs) + [CardState.waitingOnYou.rawValue, nightID]
            )

            var fired: [CardRecord] = []
            for row in rows {
                if let record = try Self.advanceOneCardUnansweredClock(
                    db, row: row, nightID: nightID, unansweredNightsMax: unansweredNightsMax, stamp: stamp
                ) {
                    fired.append(record)
                }
            }
            return fired
        }
    }

    /// Advances one Waiting-on-You Card's clock by this Night: returns the updated record only when the
    /// bound newly fired, so the caller collects just those. Split out to keep
    /// ``advanceCardUnansweredClocks(cycleIDs:nightID:unansweredNightsMax:act:runID:now:)`` within the
    /// file length limit.
    private static func advanceOneCardUnansweredClock(
        _ db: Database, row: Row, nightID: Int64, unansweredNightsMax: Int, stamp: EventStamp
    ) throws -> CardRecord? {
        let id: Int64 = row["id"]
        let unansweredNights: Int = row["unanswered_nights"]
        let newCount = unansweredNights + 1

        guard newCount > unansweredNightsMax else {
            try db.execute(
                sql: "UPDATE card SET unanswered_nights = ?, unanswered_last_counted_night_id = ? WHERE id = ?",
                arguments: [newCount, nightID, id]
            )
            return nil
        }

        try db.execute(
            sql: "UPDATE card SET unanswered_nights = ?, unanswered_last_counted_night_id = ? WHERE id = ?",
            arguments: [newCount, nightID, id]
        )

        let rawWaitingReason: String? = row["waiting_reason"]
        let blockReason: BlockReason = rawWaitingReason == WaitingReason.divergence.rawValue
            ? .undecided : .unanswered
        let issueID: String = row["issue_id"]
        _ = try Self.insertEvent(
            db,
            .cardUnansweredBoundFired(
                cardID: id, issueID: issueID, unansweredNights: newCount, bound: unansweredNightsMax,
                blockReason: blockReason.rawValue
            ),
            stamp: stamp
        )
        guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [id]) else {
            throw JournalError.cardUnknown(cardID: id)
        }
        return try Self.cardRecord(from: updated)
    }

    /// Every landed Cycle's id that currently holds a Waiting on You Card (roadmap P11.4) — what the
    /// author Act's own clock advance (``PostLandingReplies``) runs over, so it never reaches into the
    /// in-flight Cycle's Cards while that Cycle is still unlanded (the build Act owns those).
    public func landedCycleIDsWithWaitingOnYouCards() throws -> [Int64] {
        try read { db in
            try Int64.fetchAll(
                db,
                sql: """
                SELECT DISTINCT cycle.id FROM cycle
                JOIN card ON card.cycle_id = cycle.id
                WHERE cycle.landed_at IS NOT NULL AND card.state = ?
                ORDER BY cycle.id ASC
                """,
                arguments: [CardState.waitingOnYou.rawValue]
            )
        }
    }

    /// Every Card in `cycleIDs` currently Waiting on You whose unanswered-Nights count exceeds
    /// `unansweredNightsMax` — the engine's read for which Cards to auto-Block, independent of whether
    /// this tick's own advance is what pushed a Card past the bound (an Act killed between the count and
    /// the board write is completed by the next Act's read of this).
    public func cardsPastUnansweredBound(cycleIDs: [Int64], unansweredNightsMax: Int) throws -> [CardRecord] {
        guard !cycleIDs.isEmpty else { return [] }
        return try read { db in
            let placeholders = cycleIDs.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM card
                WHERE cycle_id IN (\(placeholders)) AND state = ? AND unanswered_nights > ?
                ORDER BY id ASC
                """,
                arguments: StatementArguments(cycleIDs) + [CardState.waitingOnYou.rawValue, unansweredNightsMax]
            )
            return try rows.map { try Self.cardRecord(from: $0) }
        }
    }
}
