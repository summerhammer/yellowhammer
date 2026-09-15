import Domain
import Foundation
import GRDB

/// The record that one run holds this Project's Card, refreshed by a 60-second heartbeat,
/// expiring after a 10-minute TTL with no heartbeat, so a dead run is reclaimable in minutes.
/// Sleep is more dangerous than a crash: a Mac that sleeps wakes with a run that believes it
/// still holds a Lease that expired long ago, so the Lease is revalidated before every board
/// write, not only at claim.
public struct CardLease: Equatable, Sendable {
    public let cardID: Int64      // the Journal's card.id row id
    public let runID: RunID
    public let claimedAt: Date
    public let heartbeatAt: Date
    public let expiresAt: Date

    /// A lease is held until the instant it expires; at that instant it is reclaimable.
    public func isHeld(at now: Date) -> Bool {
        expiresAt > now
    }
}

/// The outcome of asking for the Card-scoped lease.
public enum CardLeaseClaim: Equatable, Sendable {
    /// This run now holds the Card, until it releases the lease or stops heartbeating.
    case claimed(CardLease)
    /// Another run holds the Card under an unexpired lease; this run must not dispatch the Card.
    case held(CardLease)
    /// An expired lease of a different run was taken over with the new runId; the caller owns
    /// what follows (fencing sweep, classification, repost).
    case reclaimed(CardLease, expired: CardLease)
}

extension JournalStore {
    /// Claims the Card for a run, or reports the run that holds it.
    ///
    /// One write transaction, so two overlapping invocations serialise on SQLite's lock and
    /// exactly one of them sees the row first. An expired lease is taken over without ceremony:
    /// that run is dead, or asleep past its TTL, and either way it no longer holds the Card.
    /// A run that already holds the lease keeps it and refreshes the heartbeat. When a dead
    /// predecessor's lease is reclaimed, the event is recorded in the same transaction.
    public func claimCardLease(
        cardID: Int64,
        runID: RunID,
        policy: LeasePolicy = .ruled,
        now: Date = Date()
    ) throws -> CardLeaseClaim {
        let now = JournalStore.stored(now)

        return try write { db in
            // Check if the card exists
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM card WHERE id = ?", arguments: [cardID]) != nil else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let holder = try Self.fetchCardLease(db, cardID: cardID)
            if let holder, holder.runID != runID, holder.isHeld(at: now) {
                return .held(holder)
            }
            let ownHolder = holder.flatMap { $0.runID == runID ? $0 : nil }
            let lease = CardLease(
                cardID: cardID,
                runID: runID,
                claimedAt: ownHolder?.claimedAt ?? now,
                heartbeatAt: now,
                expiresAt: now.addingTimeInterval(policy.timeToLive)
            )
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO lease (card_id, run_id, claimed_at, heartbeat_at, expires_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    cardID, lease.runID.rawValue,
                    JournalStore.timestamp(lease.claimedAt),
                    JournalStore.timestamp(lease.heartbeatAt),
                    JournalStore.timestamp(lease.expiresAt)
                ]
            )
            // Record a crash reclaim if a different run's expired lease was taken over
            if let holder, holder.runID != runID, !holder.isHeld(at: now) {
                let stamp = EventStamp(act: nil, runID: runID, nightID: nil, now: now)
                let event = JournalEvent.cardLeaseReclaimed(
                    cardID: cardID,
                    previousRunID: holder.runID,
                    expiredAt: holder.expiresAt
                )
                _ = try JournalStore.insertEvent(db, event, stamp: stamp)
            }
            return .claimed(lease)
        }
    }

    /// Refreshes the lease this run holds on a Card, pushing its expiry out by the TTL, and
    /// revalidates it in the same step: if the Card is no longer this run's, because the lease
    /// expired and another run took it, or because it was released, this throws
    /// ``JournalError/cardLeaseLost(cardID:runID:holder:)``.
    /// Sleep is more dangerous than a crash, so a run heartbeats before it writes anything that
    /// assumes it still holds the Card.
    @discardableResult
    public func heartbeatCardLease(
        cardID: Int64,
        runID: RunID,
        policy: LeasePolicy = .ruled,
        now: Date = Date()
    ) throws -> CardLease {
        let now = JournalStore.stored(now)
        return try write { db in
            let holder = try Self.fetchCardLease(db, cardID: cardID)
            guard let holder, holder.runID == runID, holder.isHeld(at: now) else {
                throw JournalError.cardLeaseLost(cardID: cardID, runID: runID, holder: holder)
            }
            let refreshed = CardLease(
                cardID: cardID,
                runID: holder.runID,
                claimedAt: holder.claimedAt,
                heartbeatAt: now,
                expiresAt: now.addingTimeInterval(policy.timeToLive)
            )
            try db.execute(
                sql: "UPDATE lease SET heartbeat_at = ?, expires_at = ? WHERE card_id = ? AND run_id = ?",
                arguments: [
                    JournalStore.timestamp(refreshed.heartbeatAt),
                    JournalStore.timestamp(refreshed.expiresAt),
                    cardID,
                    runID.rawValue
                ]
            )
            return refreshed
        }
    }

    /// Revalidates the lease for a Card within an existing write transaction: fetch the row,
    /// throw `cardLeaseLost` unless held by `runID` and unexpired at `stored(now)`. Pure check,
    /// writes nothing. Used for P5.4 Outbox to check before board writes.
    public static func revalidateCardLease(
        _ db: Database,
        cardID: Int64,
        runID: RunID,
        now: Date = Date()
    ) throws -> CardLease {
        let now = JournalStore.stored(now)
        let holder = try Self.fetchCardLease(db, cardID: cardID)
        guard let holder, holder.runID == runID, holder.isHeld(at: now) else {
            throw JournalError.cardLeaseLost(cardID: cardID, runID: runID, holder: holder)
        }
        return holder
    }

    /// Convenience wrapping the static revalidation in `read`.
    public func revalidateCardLease(
        cardID: Int64,
        runID: RunID,
        now: Date = Date()
    ) throws -> CardLease {
        try read { db in
            try Self.revalidateCardLease(db, cardID: cardID, runID: runID, now: now)
        }
    }

    /// Releases the lease if this run holds it. Returns whether it did; releasing a lease another
    /// run holds is a no-op, never a takeover.
    @discardableResult
    public func releaseCardLease(cardID: Int64, runID: RunID) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "DELETE FROM lease WHERE card_id = ? AND run_id = ?",
                arguments: [cardID, runID.rawValue]
            )
            return db.changesCount == 1
        }
    }

    /// The lease row as recorded, expired or not. `nil` when no run has claimed the Card or
    /// the last holder released it.
    public func currentCardLease(cardID: Int64) throws -> CardLease? {
        try read { db in try Self.fetchCardLease(db, cardID: cardID) }
    }

    /// All leases held by a run, ordered by card_id, expired or not.
    public func cardLeases(heldBy runID: RunID) throws -> [CardLease] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM lease WHERE run_id = ? ORDER BY card_id ASC",
                arguments: [runID.rawValue]
            )
            return try rows.map { row in
                let cardID: Int64 = row["card_id"]
                return try Self.cardLease(from: row, cardID: cardID, runID: runID)
            }
        }
    }

    private static func cardLease(from row: Row, cardID: Int64, runID: RunID) throws -> CardLease {
        let onError = { JournalError.cardLeaseUnreadable(cardID: cardID) }
        return CardLease(
            cardID: cardID,
            runID: runID,
            claimedAt: try JournalStore.date(row["claimed_at"], onError: onError),
            heartbeatAt: try JournalStore.date(row["heartbeat_at"], onError: onError),
            expiresAt: try JournalStore.date(row["expires_at"], onError: onError)
        )
    }

    private static func fetchCardLease(_ db: Database, cardID: Int64) throws -> CardLease? {
        let sql = "SELECT * FROM lease WHERE card_id = ?"
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [cardID]) else {
            return nil
        }
        guard let runID = RunID(rawValue: row["run_id"]) else {
            throw JournalError.cardLeaseUnreadable(cardID: cardID)
        }
        return try Self.cardLease(from: row, cardID: cardID, runID: runID)
    }
}
