import Domain
import Foundation
import GRDB

// The refusal-drift promotion Bound (roadmap P11.6; bounds/overview), split out of
// JournalStore+Refusals.swift to keep that file under the file length limit.

extension JournalStore {
    /// Promotes a Refusal row to a standing item (roadmap P11.6) when its consecutive count exceeds
    /// `consecutiveRefusalsMax` and it is not already promoted: sets the marker and appends
    /// `refusalPromotedToStandingItem`, once per row. Split out of `recordRefusal` to keep that function
    /// within the length limit.
    static func promoteRefusalIfNeeded(
        _ db: Database, record: RefusalRecord, consecutiveRefusalsMax: Int, nightID: Int64, stamp: EventStamp
    ) throws -> RefusalRecord {
        guard record.standingItemNightID == nil, record.consecutiveRefusals > consecutiveRefusalsMax else {
            return record
        }
        try db.execute(
            sql: "UPDATE refusal SET standing_item_night_id = ? WHERE id = ?",
            arguments: [nightID, record.id]
        )
        _ = try Self.insertEvent(
            db,
            .refusalPromotedToStandingItem(
                feature: record.featureName, consecutiveRefusals: record.consecutiveRefusals,
                consecutiveRefusalsMax: consecutiveRefusalsMax
            ),
            stamp: stamp
        )
        return try Self.refusalRecord(from: try Self.fetchRefusalRow(db, id: record.id))
    }

    /// Every currently live Refusal promoted to a standing item (roadmap P11.6): the marker is set,
    /// the row is not closed, and its state is still `open` or `expired` — an `answered` one has had
    /// its decision. Oldest first.
    public func standingRefusals() throws -> [RefusalRecord] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM refusal
                WHERE standing_item_night_id IS NOT NULL AND closed_night_id IS NULL
                  AND state IN ('open', 'expired')
                ORDER BY id ASC
                """
            )
            .map { try Self.refusalRecord(from: $0) }
        }
    }
}
