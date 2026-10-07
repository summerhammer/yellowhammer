import Domain
import Foundation
import GRDB

// A Card's title (issue #161; spec: landing/announce-a-partial-landing), kept in its own file so
// JournalStore+Cards.swift stays under the file-length limit.

extension JournalStore {
    /// The board renamed the issue behind a Card: records the board's current title under the
    /// Act-scoped lease. No event: a title rename is not loop state any Act decision branches on, the
    /// same idiom as ``recordBoardSync(lastSync:runID:now:)``.
    /// Throws JournalError.cardUnknown(cardID:) when the Card does not exist.
    @discardableResult
    public func updateCardTitle(
        cardID: Int64,
        title: String,
        runID: RunID,
        now: Date = Date()
    ) throws -> CardRecord {
        try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)

            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM card WHERE id = ?", arguments: [cardID]) else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let record = try Self.cardRecord(from: row)

            try db.execute(sql: "UPDATE card SET title = ? WHERE id = ?", arguments: [title, cardID])

            return record.with(title: title)
        }
    }
}

extension CardRecord {
    func with(title: String) -> CardRecord {
        CardRecord(
            id: id,
            cycleID: cycleID,
            issueID: issueID,
            title: title,
            repository: repository,
            kind: kind,
            authoredOrder: authoredOrder,
            state: state,
            waitingReason: waitingReason,
            blockReason: blockReason,
            shelvedFromState: shelvedFromState,
            budgetEpoch: budgetEpoch,
            createdAt: createdAt,
            stateVersion: stateVersion,
            boardStateVersion: boardStateVersion,
            unansweredNights: unansweredNights,
            unansweredLastCountedNightID: unansweredLastCountedNightID,
            failedAdoptions: failedAdoptions,
            divergenceStandingNightID: divergenceStandingNightID,
            issueKey: issueKey,
            issueURL: issueURL
        )
    }
}
