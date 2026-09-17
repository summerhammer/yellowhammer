import Domain
import Foundation
import GRDB

extension JournalStore {
    /// Records a Card's Architectural Brief prose, upserting the one row `architectural_brief` keeps
    /// per Card.
    public func recordArchitecturalBrief(cardID: Int64, prose: String, now: Date = Date()) throws {
        let stored = JournalStore.timestamp(JournalStore.stored(now))
        try write { db in
            try db.execute(
                sql: """
                INSERT INTO architectural_brief (card_id, prose, recorded_at) VALUES (?, ?, ?)
                ON CONFLICT(card_id) DO UPDATE SET prose = excluded.prose, recorded_at = excluded.recorded_at
                """,
                arguments: [cardID, prose, stored]
            )
        }
    }

    /// The Card's Architectural Brief prose, or nil when none is recorded.
    public func architecturalBriefProse(cardID: Int64) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT prose FROM architectural_brief WHERE card_id = ?", arguments: [cardID])
        }
    }
}
