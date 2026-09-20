import Domain
import Foundation
import GRDB

extension JournalStore {
    /// Records a Card's Architectural Brief prose, upserting the one row `architectural_brief` keeps
    /// per Card.
    public func recordArchitecturalBrief(cardID: Int64, prose: String, now: Date = Date()) throws {
        let stored = JournalStore.timestamp(JournalStore.stored(now))
        try write { db in
            try Self.insertArchitecturalBrief(db, cardID: cardID, prose: prose, timestamp: stored)
        }
    }

    /// Upserts one Card's Architectural Brief row. Shared with ``finaliseAuthoring(_:runID:act:nightID:now:)``
    /// (roadmap P9.6) so a newly authored Card's brief is written in the same transaction as its Feature,
    /// Cycle and Card rows, without duplicating the SQL.
    static func insertArchitecturalBrief(_ db: Database, cardID: Int64, prose: String, timestamp: String) throws {
        try db.execute(
            sql: """
            INSERT INTO architectural_brief (card_id, prose, recorded_at) VALUES (?, ?, ?)
            ON CONFLICT(card_id) DO UPDATE SET prose = excluded.prose, recorded_at = excluded.recorded_at
            """,
            arguments: [cardID, prose, timestamp]
        )
    }

    /// The Card's Architectural Brief prose, or nil when none is recorded.
    public func architecturalBriefProse(cardID: Int64) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT prose FROM architectural_brief WHERE card_id = ?", arguments: [cardID])
        }
    }
}
