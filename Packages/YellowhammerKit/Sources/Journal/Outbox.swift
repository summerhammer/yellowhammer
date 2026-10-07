import Domain
import Foundation
import GRDB

/// The delivery state of an Outbox entry: pending, applied, failed, or aborted (never sent).
public enum OutboxEntryState: String, Sendable {
    case pending, applied, failed, aborted
}

/// One accepted board write as the Journal holds it.
public struct OutboxEntry: Equatable, Sendable {
    public let id: Int64
    public let clientID: UUID          // outbox.client_id — store as lowercased uuidString
    public let issueID: String?
    public let operation: String
    public let payload: String
    public let runID: RunID?           // the run that accepted it
    public let cardID: Int64?
    public let groupID: String?
    public let state: OutboxEntryState
    public let attemptCount: Int
    public let createdAt: Date
    public let sentAt: Date?
    public let lastError: String?
    public let result: String?
}

/// What the Engine asks the Journal to accept.
public struct OutboxDraft: Equatable, Sendable {
    public var clientID: UUID
    public var issueID: String?
    public var operation: String
    public var payload: String
    public var cardID: Int64?
    public var groupID: String?

    public init(
        clientID: UUID,
        issueID: String? = nil,
        operation: String,
        payload: String,
        cardID: Int64? = nil,
        groupID: String? = nil
    ) {
        self.clientID = clientID
        self.issueID = issueID
        self.operation = operation
        self.payload = payload
        self.cardID = cardID
        self.groupID = groupID
    }
}

extension JournalStore {
    /// Accepts drafts in ONE write transaction, after `revalidateActLease(db, runID:, now:)`. Uses
    /// `INSERT OR IGNORE` keyed on client_id so accepting the same client id twice is idempotent:
    /// the existing row is returned untouched (its state, result etc. preserved). Returns entries in
    /// draft order.
    ///
    /// `event`, when given, is appended in the SAME transaction and only if a draft was newly inserted:
    /// the authoring plan and its group are recorded together or not at all.
    public func acceptOutbox(
        _ drafts: [OutboxDraft],
        runID: RunID,
        now: Date = Date(),
        appending event: JournalEvent? = nil,
        act: Act? = nil,
        nightID: Int64? = nil
    ) throws -> [OutboxEntry] {
        let now = JournalStore.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            var results: [OutboxEntry] = []
            var inserted = false // whether any draft was new
            let timestamp = JournalStore.timestamp(now)

            for draft in drafts {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO outbox
                    (client_id, issue_id, operation, payload, run_id, created_at, state, attempt_count,
                     card_id, group_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        draft.clientID.uuidString.lowercased(),
                        draft.issueID,
                        draft.operation,
                        draft.payload,
                        runID.rawValue,
                        timestamp,
                        OutboxEntryState.pending.rawValue,
                        0,
                        draft.cardID,
                        draft.groupID
                    ]
                )

                inserted = inserted || db.changesCount > 0
                // Fetch and return the entry (either newly inserted or existing)
                let entry = try Self.fetchOutboxByClientID(db, clientID: draft.clientID)
                guard let entry else {
                    throw JournalError.outboxEntryUnknown(id: -1)
                }
                results.append(entry)
            }

            if let event, inserted {
                let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
                _ = try Self.insertEvent(db, event, stamp: stamp)
            }
            return results
        }
    }

    /// Fetch an Outbox entry by its client ID.
    public func outboxEntry(clientID: UUID) throws -> OutboxEntry? {
        try read { db in try Self.fetchOutboxByClientID(db, clientID: clientID) }
    }

    /// Fetch an Outbox entry by its id.
    public func outboxEntry(id: Int64) throws -> OutboxEntry? {
        try read { db in try Self.fetchOutboxByID(db, id: id) }
    }

    /// Every entry with state 'pending', ORDER BY id ASC (replay order after a crash).
    public func pendingOutboxEntries() throws -> [OutboxEntry] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE state = ? ORDER BY id ASC",
                arguments: [OutboxEntryState.pending.rawValue]
            )
            return try rows.map { row in
                let id: Int64 = row["id"]
                return try Self.outboxEntry(from: row, id: id)
            }
        }
    }

    /// All entries with the given group_id, ORDER BY id ASC.
    public func outboxEntries(groupID: String) throws -> [OutboxEntry] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM outbox WHERE group_id = ? ORDER BY id ASC",
                arguments: [groupID]
            )
            return try rows.map { row in
                let id: Int64 = row["id"]
                return try Self.outboxEntry(from: row, id: id)
            }
        }
    }

    /// Lease revalidation before a board write: Act lease for `runID` and, when `entry.cardID` is
    /// set, that Card's lease. Pure read: writes nothing. Throws the corresponding JournalError
    /// (actLeaseLost / cardLeaseLost).
    public func revalidateOutboxLeases(
        for entry: OutboxEntry,
        runID: RunID,
        now: Date = Date()
    ) throws {
        try read { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            if let cardID = entry.cardID {
                _ = try Self.revalidateCardLease(db, cardID: cardID, runID: runID, now: now)
            }
        }
    }

    /// pending → applied; sets sent_at = stored(now), result, clears last_error. Returns the
    /// updated entry.
    @discardableResult
    public func markOutboxApplied(
        id: Int64,
        result: String?,
        now: Date = Date()
    ) throws -> OutboxEntry {
        let now = JournalStore.stored(now)
        return try write { db in
            guard let entry = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            guard entry.state == .pending else {
                throw JournalError.outboxEntryNotPending(id: id, state: entry.state)
            }

            try db.execute(
                sql: """
                UPDATE outbox SET state = ?, sent_at = ?, result = ?, last_error = NULL WHERE id = ?
                """,
                arguments: [
                    OutboxEntryState.applied.rawValue,
                    JournalStore.timestamp(now),
                    result,
                    id
                ]
            )

            guard let updated = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            return updated
        }
    }

    /// pending → failed (permanent); sets last_error. Returns the updated entry.
    @discardableResult
    public func markOutboxFailed(
        id: Int64,
        error: String,
        now: Date = Date()
    ) throws -> OutboxEntry {
        try write { db in
            guard let entry = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            guard entry.state == .pending else {
                throw JournalError.outboxEntryNotPending(id: id, state: entry.state)
            }

            try db.execute(
                sql: "UPDATE outbox SET state = ?, last_error = ? WHERE id = ?",
                arguments: [OutboxEntryState.failed.rawValue, error, id]
            )

            guard let updated = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            return updated
        }
    }

    /// pending → aborted (never sent: lease lost / broken delimiters / group rolled back); sets
    /// last_error = reason. Returns the updated entry.
    @discardableResult
    public func markOutboxAborted(
        id: Int64,
        reason: String,
        now: Date = Date()
    ) throws -> OutboxEntry {
        try write { db in
            guard let entry = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            guard entry.state == .pending else {
                throw JournalError.outboxEntryNotPending(id: id, state: entry.state)
            }

            try db.execute(
                sql: "UPDATE outbox SET state = ?, last_error = ? WHERE id = ?",
                arguments: [OutboxEntryState.aborted.rawValue, reason, id]
            )

            guard let updated = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            return updated
        }
    }

    /// Aborts every pending Outbox entry for `issueID` (graph-execution/handle-a-block-mid-graph and
    /// run-a-card, P8.9): shared by ``ManagedBlockMaintenance`` (a Card the Journal already holds
    /// Shelved) and ``DeltaRead`` (the Act that just read the Card as Shelved), so both write the
    /// same "nothing is posted to it" record rather than each looping over `pendingOutboxEntries()`.
    public func abortPendingOutboxEntries(issueID: String, reason: String) throws {
        for entry in try pendingOutboxEntries() where entry.issueID == issueID {
            _ = try markOutboxAborted(id: entry.id, reason: reason)
        }
    }

    /// Stays pending; attempt_count += 1; last_error = error. For transient failures
    /// (unreachable, unreadable).
    @discardableResult
    public func recordOutboxAttemptFailure(
        id: Int64,
        error: String
    ) throws -> OutboxEntry {
        try write { db in
            guard let entry = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }

            try db.execute(
                sql: "UPDATE outbox SET attempt_count = attempt_count + 1, last_error = ? WHERE id = ?",
                arguments: [error, id]
            )

            guard let updated = try Self.fetchOutboxByID(db, id: id) else {
                throw JournalError.outboxEntryUnknown(id: id)
            }
            return updated
        }
    }

    /// Upsert into the managed_block table (issue_id PK, last_posted_hash, posted_at).
    public func recordManagedBlockPosted(
        issueID: String,
        hash: String,
        now: Date = Date()
    ) throws {
        let now = JournalStore.stored(now)
        try write { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO managed_block (issue_id, last_posted_hash, posted_at)
                VALUES (?, ?, ?)
                """,
                arguments: [issueID, hash, JournalStore.timestamp(now)]
            )
        }
    }

    /// Fetch the last posted hash for a managed block by issue_id.
    public func managedBlockLastPostedHash(issueID: String) throws -> String? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT last_posted_hash FROM managed_block WHERE issue_id = ?",
                arguments: [issueID]
            ) else {
                return nil
            }
            return row["last_posted_hash"]
        }
    }

    // MARK: - Private Helpers

    private static func fetchOutboxByClientID(_ db: Database, clientID: UUID) throws -> OutboxEntry? {
        let sql = "SELECT * FROM outbox WHERE client_id = ?"
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [clientID.uuidString.lowercased()])
        else {
            return nil
        }
        let id: Int64 = row["id"]
        return try Self.outboxEntry(from: row, id: id)
    }

    private static func fetchOutboxByID(_ db: Database, id: Int64) throws -> OutboxEntry? {
        let sql = "SELECT * FROM outbox WHERE id = ?"
        guard let row = try Row.fetchOne(db, sql: sql, arguments: [id]) else {
            return nil
        }
        return try Self.outboxEntry(from: row, id: id)
    }

    private static func outboxEntry(from row: Row, id: Int64) throws -> OutboxEntry {
        let onError = { JournalError.outboxEntryUnreadable(id: id) }

        guard let clientIDStr: String = row["client_id"] else {
            throw onError()
        }
        guard let clientID = UUID(uuidString: clientIDStr) else {
            throw onError()
        }

        guard let stateStr: String = row["state"] else {
            throw onError()
        }
        guard let state = OutboxEntryState(rawValue: stateStr) else {
            throw onError()
        }

        let issueID: String? = row["issue_id"]
        let operation: String = row["operation"]
        let payload: String = row["payload"]
        let runIDStr: String? = row["run_id"]
        let runID = runIDStr.flatMap { RunID(rawValue: $0) }
        let cardID: Int64? = row["card_id"]
        let groupID: String? = row["group_id"]
        let attemptCount: Int = row["attempt_count"]
        let lastError: String? = row["last_error"]
        let result: String? = row["result"]

        let createdAt = try JournalStore.date(row["created_at"], onError: onError)
        let sentAt = try (row["sent_at"] as String?).map { text in
            try JournalStore.date(text, onError: onError)
        }

        return OutboxEntry(
            id: id,
            clientID: clientID,
            issueID: issueID,
            operation: operation,
            payload: payload,
            runID: runID,
            cardID: cardID,
            groupID: groupID,
            state: state,
            attemptCount: attemptCount,
            createdAt: createdAt,
            sentAt: sentAt,
            lastError: lastError,
            result: result
        )
    }
}
