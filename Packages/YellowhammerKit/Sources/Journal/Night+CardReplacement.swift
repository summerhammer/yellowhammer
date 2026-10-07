import Domain
import Foundation
import GRDB

extension JournalStore {
    /// All archived Night Cards, in replacement order. The Night row names the current card.
    public func archivedNightCardIssueIDs(nightID: Int64) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT issue_id FROM night_card_predecessor WHERE night_id = ? ORDER BY generation
                """, arguments: [nightID])
        }
    }

    /// Advances only the expected predecessor, atomically retaining its identity and clearing display
    /// metadata. Replaying the same replacement is a no-op; a stale replacement cannot overwrite it.
    @discardableResult
    public func replaceNightCard(
        id: Int64, predecessorIssueID: String, issueID: String, act: Act, runID: RunID, now: Date = Date()
    ) throws -> NightRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: JournalStore.stored(now))
            guard let current: String = try String.fetchOne(
                db, sql: "SELECT night_card_issue_id FROM night WHERE id = ?", arguments: [id]
            ) else { throw JournalError.nightUnknown(id: id) }
            if current == issueID { return }
            guard current == predecessorIssueID, current != issueID else {
                throw JournalError.nightCardAlreadyRecorded(id: id, issueID: current)
            }
            try db.execute(sql: """
                INSERT INTO night_card_predecessor (night_id, issue_id, generation)
                SELECT ?, ?, COUNT(*) FROM night_card_predecessor WHERE night_id = ?
                """, arguments: [id, predecessorIssueID, id])
            try db.execute(sql: """
                UPDATE night SET night_card_issue_id = ?, night_card_issue_id_for_display = NULL,
                    night_card_issue_key = NULL, night_card_issue_url = NULL WHERE id = ?
                """, arguments: [issueID, id])
            _ = try Self.insertEvent(db, .nightCardOpened(issueID: issueID),
                stamp: EventStamp(act: act, runID: runID, nightID: id, now: now))
        }
        guard let updated = try night(id: id) else { throw JournalError.nightUnknown(id: id) }
        return updated
    }
}
