import Domain
import Foundation
import GRDB

// A failed Adoption's durable Divergence record (roadmap P11.5; spec: feature-authoring/
// author-the-cycle-and-card-dag, second story): one row per refusal, in `adoption_refusal`
// (``JournalMigrations/createAdoptionRefusalTable(_:)``), queryable per Card for the Managed Block's
// notice. A sibling of Refusal, never reusing its tables or event.

/// One row of `adoption_refusal`: a Card a selection tried to adopt, refused because at least one
/// Transcription Block tested stale.
public struct AdoptionRefusalRecord: Equatable, Sendable {
    public let id: Int64
    public let cardID: Int64
    public let nightID: Int64
    public let featureName: String
    public let staleBlocks: [AdoptionStaleBlock]
    public let createdAt: Date
}

extension JournalStore {
    /// Records a failed Adoption, in one write transaction: inserts the durable `adoption_refusal` row,
    /// increments `card.failed_adoptions` and `card.consecutive_divergences`, and appends
    /// `.adoptionRefused`. This stands even if the authoring transaction that tried the Adoption later
    /// rolls back — it is written outside that Outbox group, before the breakdown is drafted.
    @discardableResult
    public func recordAdoptionRefusal(
        cardID: Int64, nightID: Int64, featureName: String, staleBlocks: [AdoptionStaleBlock],
        act: Act? = nil, runID: RunID? = nil, now: Date = Date()
    ) throws -> AdoptionRefusalRecord {
        try write { db in
            guard
                let issueID = try String.fetchOne(
                    db, sql: "SELECT issue_id FROM card WHERE id = ?", arguments: [cardID]
                )
            else {
                throw JournalError.cardUnknown(cardID: cardID)
            }
            let timestamp = JournalStore.timestamp(JournalStore.stored(now))
            let encoded = Self.encodeStaleBlocks(staleBlocks)
            try db.execute(
                sql: """
                INSERT INTO adoption_refusal (card_id, night_id, feature_name, stale_blocks, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [cardID, nightID, featureName, encoded, timestamp]
            )
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                UPDATE card
                SET failed_adoptions = failed_adoptions + 1, consecutive_divergences = consecutive_divergences + 1
                WHERE id = ?
                """,
                arguments: [cardID]
            )
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: JournalStore.stored(now))
            _ = try Self.insertEvent(
                db,
                .adoptionRefused(
                    cardID: cardID, issueID: issueID, nightID: nightID, featureName: featureName,
                    staleBlocks: staleBlocks
                ),
                stamp: stamp
            )
            return AdoptionRefusalRecord(
                id: id, cardID: cardID, nightID: nightID, featureName: featureName,
                staleBlocks: staleBlocks, createdAt: JournalStore.stored(now)
            )
        }
    }

    /// Every recorded adoption refusal for `cardID`, oldest first — accumulates, one row per failed
    /// Adoption, never overwritten.
    public func adoptionRefusals(cardID: Int64) throws -> [AdoptionRefusalRecord] {
        try read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM adoption_refusal WHERE card_id = ? ORDER BY id ASC", arguments: [cardID]
            )
            return try rows.map { try Self.adoptionRefusalRecord(from: $0) }
        }
    }

    /// The latest recorded adoption refusal for `cardID`, or nil when it has none.
    public func latestAdoptionRefusal(cardID: Int64) throws -> AdoptionRefusalRecord? {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM adoption_refusal WHERE card_id = ? ORDER BY id DESC LIMIT 1",
                    arguments: [cardID]
                )
            else {
                return nil
            }
            return try Self.adoptionRefusalRecord(from: row)
        }
    }

    /// Whether the latest adoption refusal for `cardID` is still the reason it is Waiting on You: true
    /// only when no later event has moved the Card through another Divergence (a readiness-check
    /// Divergence, `.cardDiverged`) since. Used to render the Managed Block's adoption-refusal notice
    /// only while it is still current — a later readiness Divergence supersedes it, and a second
    /// adoption refusal replaces rather than stacks (its own row is simply the new latest).
    public func latestDivergenceIsAdoptionRefusal(cardID: Int64) throws -> AdoptionRefusalRecord? {
        guard let refusal = try latestAdoptionRefusal(cardID: cardID) else { return nil }
        let laterDiverged = try events(ofType: .cardDiverged).contains {
            guard case .cardDiverged(let diveredCardID, _, _, _) = $0.event, diveredCardID == cardID else {
                return false
            }
            return $0.id > refusal.id
        }
        return laterDiverged ? nil : refusal
    }

    /// Resets `card.failed_adoptions` and `card.consecutive_divergences` to 0, on a clean Adoption
    /// (roadmap P11.5).
    public func resetFailedAdoptions(cardID: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE card SET failed_adoptions = 0, consecutive_divergences = 0 WHERE id = ?",
                arguments: [cardID]
            )
        }
    }

    private static func encodeStaleBlocks(_ blocks: [AdoptionStaleBlock]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(blocks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func adoptionRefusalRecord(from row: Row) throws -> AdoptionRefusalRecord {
        let id: Int64 = row["id"]
        let raw: String = row["stale_blocks"]
        let decoder = JSONDecoder()
        let staleBlocks = (try? decoder.decode([AdoptionStaleBlock].self, from: Data(raw.utf8))) ?? []
        let createdAtText: String = row["created_at"]
        let createdAt = try Self.date(createdAtText) { JournalError.eventUnreadable(id: id) }
        return AdoptionRefusalRecord(
            id: id, cardID: row["card_id"], nightID: row["night_id"], featureName: row["feature_name"],
            staleBlocks: staleBlocks, createdAt: createdAt
        )
    }
}
