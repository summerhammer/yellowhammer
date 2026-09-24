import Domain
import Foundation
import GRDB

/// The heartbeat and time-to-live a Lease is held under: 60 seconds and 10 minutes, confirmed by
/// the Decision Gates Ruling (G-15) and merely true today, to be revised only from observed reclaims.
///
/// Note: Timestamps are stored to whole-second precision. The effective time-to-live is therefore
/// `timeToLive` minus up to one second, since a lease claimed near the end of second T expires at the
/// beginning of second T + `timeToLive`. For reliable heartbeat extension, `timeToLive` must be at
/// least 2 seconds and comfortably above `heartbeatInterval` (the ruled values 600 and 60 satisfy this).
public struct LeasePolicy: Equatable, Sendable {
    public var heartbeatInterval: TimeInterval
    public var timeToLive: TimeInterval

    public init(heartbeatInterval: TimeInterval, timeToLive: TimeInterval) {
        self.heartbeatInterval = heartbeatInterval
        self.timeToLive = timeToLive
    }

    /// The heartbeat interval as a Duration for use with Task.sleep.
    public var heartbeatDuration: Duration {
        Duration.seconds(heartbeatInterval)
    }

    public static let ruled = LeasePolicy(heartbeatInterval: 60, timeToLive: 600)
}

/// The record that one run holds this Project for an Act. There is at most one per Journal: two
/// Acts of the same Project must not run at once, and a crashed Act frees the Project by timeout.
public struct ActLease: Equatable, Sendable {
    public let act: Act
    public let runID: RunID
    public let mode: NightMode
    public let claimedAt: Date
    public let heartbeatAt: Date
    public let expiresAt: Date

    /// A lease is held until the instant it expires; at that instant it is reclaimable.
    public func isHeld(at now: Date) -> Bool {
        expiresAt > now
    }
}

/// The outcome of asking for the Act-scoped lease.
public enum ActLeaseClaim: Equatable, Sendable {
    /// This run now holds the Project, until it releases the lease or stops heartbeating.
    case claimed(ActLease)
    /// Another run holds the Project under an unexpired lease; this run must stand down, out loud.
    case held(ActLease)
}

extension JournalStore {
    /// Claims the Project for an Act, or reports the run that holds it.
    ///
    /// One write transaction, so two overlapping invocations of the same Project serialise on SQLite's
    /// lock and exactly one of them sees the row first. An expired lease is taken over without ceremony:
    /// that run is dead, or asleep past its TTL, and either way it no longer holds the Project. A run
    /// that already holds the lease keeps it and refreshes the heartbeat. When a dead predecessor's
    /// lease is reclaimed, the event is recorded in the same transaction.
    public func claimActLease(
        act: Act,
        runID: RunID,
        mode: NightMode,
        policy: LeasePolicy = .ruled,
        now: Date = Date()
    ) throws -> ActLeaseClaim {
        let now = JournalStore.stored(now)
        return try write { db in
            let holder = try Self.fetchActLease(db)
            if let holder, holder.runID != runID, holder.isHeld(at: now) {
                return .held(holder)
            }
            let ownHolder = holder.flatMap { $0.runID == runID ? $0 : nil }
            let lease = ActLease(
                act: act,
                runID: runID,
                mode: mode,
                claimedAt: ownHolder?.claimedAt ?? now,
                heartbeatAt: now,
                expiresAt: now.addingTimeInterval(policy.timeToLive)
            )
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO act_lease (id, act, run_id, mode, claimed_at, heartbeat_at, expires_at)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    lease.act.rawValue, lease.runID.rawValue, lease.mode.rawValue,
                    JournalStore.timestamp(lease.claimedAt),
                    JournalStore.timestamp(lease.heartbeatAt),
                    JournalStore.timestamp(lease.expiresAt)
                ]
            )
            // Record a crash reclaim if a different run's expired lease was taken over
            if let holder, holder.runID != runID, !holder.isHeld(at: now) {
                let stamp = EventStamp(act: act, runID: runID, nightID: nil, now: now)
                let event = JournalEvent.leaseReclaimed(
                    previousRunID: holder.runID, previousAct: holder.act, expiredAt: holder.expiresAt
                )
                _ = try JournalStore.insertEvent(db, event, stamp: stamp)
            }
            return .claimed(lease)
        }
    }

    /// Revalidates the Act-scoped lease within an existing write transaction: fetch the row,
    /// throw `actLeaseLost` unless held by `runID` and unexpired at `stored(now)`. Pure check,
    /// writes nothing. Used for board writes to check before assuming the Project is ours.
    public static func revalidateActLease(
        _ db: Database,
        runID: RunID,
        now: Date = Date()
    ) throws -> ActLease {
        let now = JournalStore.stored(now)
        let holder = try Self.fetchActLease(db)
        guard let holder, holder.runID == runID, holder.isHeld(at: now) else {
            throw JournalError.actLeaseLost(runID: runID, holder: holder)
        }
        return holder
    }

    /// Convenience wrapping the static revalidation in `read`.
    public func revalidateActLease(runID: RunID, now: Date = Date()) throws -> ActLease {
        try read { db in
            try Self.revalidateActLease(db, runID: runID, now: now)
        }
    }

    /// Refreshes the lease this run holds, pushing its expiry out by the TTL, and revalidates it in the
    /// same step: if the Project is no longer this run's, because the lease expired and another run
    /// took it, or because it was released, this throws ``JournalError/actLeaseLost(runID:holder:)``.
    /// Sleep is more dangerous than a crash, so a run heartbeats before it writes anything that
    /// assumes it still holds the Project.
    @discardableResult
    public func heartbeatActLease(
        runID: RunID,
        policy: LeasePolicy = .ruled,
        now: Date = Date()
    ) throws -> ActLease {
        let now = JournalStore.stored(now)
        return try write { db in
            let holder = try Self.revalidateActLease(db, runID: runID, now: now)
            let refreshed = ActLease(
                act: holder.act,
                runID: holder.runID,
                mode: holder.mode,
                claimedAt: holder.claimedAt,
                heartbeatAt: now,
                expiresAt: now.addingTimeInterval(policy.timeToLive)
            )
            try db.execute(
                sql: "UPDATE act_lease SET heartbeat_at = ?, expires_at = ? WHERE id = 1 AND run_id = ?",
                arguments: [
                    JournalStore.timestamp(refreshed.heartbeatAt),
                    JournalStore.timestamp(refreshed.expiresAt),
                    runID.rawValue
                ]
            )
            return refreshed
        }
    }

    /// Releases the lease if this run holds it. Returns whether it did; releasing a lease another run
    /// holds is a no-op, never a takeover.
    @discardableResult
    public func releaseActLease(runID: RunID) throws -> Bool {
        try write { db in
            try db.execute(sql: "DELETE FROM act_lease WHERE id = 1 AND run_id = ?", arguments: [runID.rawValue])
            return db.changesCount == 1
        }
    }

    /// The lease row as recorded, expired or not. `nil` when no run has claimed the Project or the
    /// last holder released it.
    public func currentActLease() throws -> ActLease? {
        try read { db in try Self.fetchActLease(db) }
    }

    static func fetchActLease(_ db: Database) throws -> ActLease? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM act_lease WHERE id = 1") else {
            return nil
        }
        guard
            let act = Act(rawValue: row["act"]),
            let runID = RunID(rawValue: row["run_id"]),
            let mode = NightMode(rawValue: row["mode"])
        else {
            throw JournalError.actLeaseUnreadable
        }
        return ActLease(
            act: act,
            runID: runID,
            mode: mode,
            claimedAt: try JournalStore.date(row["claimed_at"]) { JournalError.actLeaseUnreadable },
            heartbeatAt: try JournalStore.date(row["heartbeat_at"]) { JournalError.actLeaseUnreadable },
            expiresAt: try JournalStore.date(row["expires_at"]) { JournalError.actLeaseUnreadable }
        )
    }
}
