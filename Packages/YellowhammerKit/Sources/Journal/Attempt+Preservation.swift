import Domain
import Foundation
import GRDB

// The Journal write the fence → WIP-commit → preserve → reset sequence needs (Attempt, Block and
// Reset Ruling 2026-09-19, OQ60), split out of Attempt.swift to keep it under the file length limit.

extension JournalStore {
    /// Records that `attemptID`'s own commits plus any WIP commit were preserved under `ref` at
    /// `commit`, just before the Worktree and the Feature Branch tip were reset to `resetTo`. One
    /// write transaction, revalidating the Act-scoped lease before writing.
    ///
    /// Idempotent: when `attemptID` already carries this same `ref` and `commit`, this writes nothing
    /// and appends no second event — the physical reset itself is idempotent (a second run creates no
    /// second ref), so a retried write here must not duplicate the Journal's account of it either.
    @discardableResult
    public func recordAttemptPreservation(
        attemptID: Int64,
        ref: String,
        commit: String,
        resetTo: String,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        now: Date = Date()
    ) throws -> AttemptRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let before = try Self.fetchAttempt(db, attemptID: attemptID) else {
                throw JournalError.attemptUnknown(attemptID: attemptID)
            }
            guard before.preservedRef != ref || before.preservedCommit != commit else {
                return before
            }

            try db.execute(
                sql: "UPDATE attempt SET preserved_ref = ?, preserved_commit = ? WHERE id = ?",
                arguments: [ref, commit, attemptID]
            )

            guard let cardRow = try Row.fetchOne(
                db, sql: "SELECT issue_id FROM card WHERE id = ?", arguments: [before.cardID]
            ) else {
                throw JournalError.cardUnknown(cardID: before.cardID)
            }
            let issueID: String = cardRow["issue_id"]

            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            let event = JournalEvent.attemptWorkPreserved(
                cardID: before.cardID, issueID: issueID, attemptID: attemptID, ref: ref, commit: commit,
                resetTo: resetTo
            )
            _ = try Self.insertEvent(db, event, stamp: stamp)

            guard let record = try Self.fetchAttempt(db, attemptID: attemptID) else {
                throw JournalError.attemptUnknown(attemptID: attemptID)
            }
            return record
        }
    }
}
