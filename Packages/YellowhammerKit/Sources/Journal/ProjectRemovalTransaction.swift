import Domain
import Foundation
import GRDB

/// Removal owns a SQLite writer transaction, rather than impersonating an author, build or land Act.
/// Other connections retain their committed snapshot; all competing writers refuse on the bounded
/// SQLite busy timeout. A process death rolls the transaction back, including Outbox delivery evidence.
public enum ProjectRemovalTransactionError: Error, CustomStringConvertible {
    case finished

    public var description: String { "the Project removal transaction no longer holds the Journal" }
}

extension JournalStore {
    /// Opens a dedicated connection and takes the writer lock before confirmation or remote effects.
    /// No lease row, receipt, counter or event is committed until `commitProjectRemoval` succeeds.
    public func beginProjectRemoval(
        runID: RunID, now: Date = Date(), holding removalHold: ProjectRemovalHold? = nil,
        exclusiveWait: Duration = ProjectRemovalHold.exclusiveWait
    ) throws -> JournalStore {
        let removalHold = try removalHold ?? .exclusive(for: fileURL, wait: exclusiveWait)
        try removalHold.validate(journalURL: fileURL)
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(Self.busyTimeout)
        configuration.allowsUnsafeTransactions = true
        let connection = try DatabaseQueue(path: fileURL.path, configuration: configuration)
        try connection.writeWithoutTransaction { db in
            try db.beginTransaction(.immediate)
            do {
                if let holder = try Self.fetchActLease(db), holder.isHeld(at: Self.stored(now)) {
                    throw JournalError.projectRemovalRefused(holder: holder)
                }
            } catch {
                try db.rollback()
                throw error
            }
        }
        return JournalStore(
            projectID: projectID, fileURL: fileURL, queue: connection, outboxSalt: outboxSalt,
            linearWorkspace: linearWorkspace, removalRunID: runID, removalHold: removalHold
        )
    }

    public func projectRemovalRunID() throws -> RunID {
        guard let removalRunID else { throw ProjectRemovalTransactionError.finished }
        try revalidateProjectRemoval(runID: removalRunID)
        return removalRunID
    }

    public func commitProjectRemoval() throws {
        guard removalRunID != nil else { throw ProjectRemovalTransactionError.finished }
        try queue.writeWithoutTransaction { db in
            guard db.isInsideTransaction else { throw ProjectRemovalTransactionError.finished }
            try db.commit()
        }
    }

    /// Rolls back whatever removal has not committed and ends its exclusive hold: the last thing
    /// removal does, after the TOML deletion when it succeeded, so it is a no-op on the Journal then.
    public func rollbackProjectRemoval() {
        guard removalRunID != nil else { return }
        try? queue.writeWithoutTransaction { db in
            if db.isInsideTransaction { try db.rollback() }
        }
        removalHold?.release()
    }

    /// Revalidates removal's authority immediately before a board mutation. The transaction cannot
    /// expire during sleep or be taken over: SQLite retains its writer lock until commit/rollback/death.
    /// Normal Act and Card lease checks use the existing paths without this authority.
    public func revalidateProjectRemoval(runID: RunID) throws {
        guard removalRunID == runID else { throw ProjectRemovalTransactionError.finished }
        try read { _ in }
    }

    public func isProjectRemoval(runID: RunID) -> Bool { removalRunID == runID }

    func revalidateOutboxAuthority(_ db: Database, runID: RunID, now: Date) throws {
        if removalRunID == runID {
            guard db.isInsideTransaction else { throw ProjectRemovalTransactionError.finished }
        } else {
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
        }
    }

    /// Reconciles an applied Night Card create receipt without running the opening/provisioning path.
    /// A replacement accepted before removal retains the exact predecessor chain, and never creates.
    public func reconcileRemovalNightCard(
        nightID: Int64, issueID: String, runID: RunID, now: Date = Date()
    ) throws {
        try revalidateProjectRemoval(runID: runID)
        guard let night = try night(id: nightID) else { throw JournalError.nightUnknown(id: nightID) }
        try write { db in
            guard night.nightCardIssueID != issueID else { return }
            if let predecessor = night.nightCardIssueID {
                try db.execute(sql: """
                    INSERT INTO night_card_predecessor (night_id, issue_id, generation)
                    SELECT ?, ?, COUNT(*) FROM night_card_predecessor WHERE night_id = ?
                    """, arguments: [nightID, predecessor, nightID])
            }
            try db.execute(sql: """
                UPDATE night SET night_card_issue_id = ?, night_card_issue_id_for_display = NULL,
                    night_card_issue_key = NULL, night_card_issue_url = NULL WHERE id = ?
                """, arguments: [issueID, nightID])
            _ = try Self.insertEvent(db, .nightCardOpened(issueID: issueID),
                stamp: EventStamp(act: nil, runID: runID, nightID: nightID, now: now))
        }
    }
}
