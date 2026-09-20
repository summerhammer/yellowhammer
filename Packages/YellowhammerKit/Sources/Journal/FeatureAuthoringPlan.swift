import Foundation

// The durable plan of one authoring transaction (roadmap P9.4; spec: feature-authoring/
// author-the-cycle-and-card-dag). It is recorded in the same Journal transaction that accepts the
// transaction's Outbox group, so a resumed author Act finishes exactly what was planned.

/// One Definition of Done clause the plan mints for an issue (roadmap P9.5; spec: feature-authoring/
/// author-citable-definitions-of-done, first story): its synthetic `cid`, its text, and the citation
/// that resolved before this clause was accepted into the Outbox.
public struct PlannedClause: Codable, Equatable, Sendable {
    public let cid: String
    public let text: String
    public let citation: String

    public init(cid: String, text: String, citation: String) {
        self.cid = cid
        self.text = text
        self.citation = citation
    }
}

/// One Card the plan creates: the Outbox key its create was accepted under, and the Journal row it
/// becomes once the board has applied it.
public struct PlannedCard: Codable, Equatable, Sendable {
    public let key: String
    public let repository: String
    public let kind: String
    public let order: Int
    public let title: String
    /// This Card's citable Definition of Done clauses (roadmap P9.5); empty for a P9.4-era plan decoded
    /// from a legacy `featureAuthoringAccepted` event.
    public let clauses: [PlannedClause]

    public init(
        key: String, repository: String, kind: String, order: Int, title: String, clauses: [PlannedClause] = []
    ) {
        self.key = key
        self.repository = repository
        self.kind = kind
        self.order = order
        self.title = title
        self.clauses = clauses
    }

    private enum CodingKeys: String, CodingKey {
        case key, repository, kind, order, title, clauses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        repository = try container.decode(String.self, forKey: .repository)
        kind = try container.decode(String.self, forKey: .kind)
        order = try container.decode(Int.self, forKey: .order)
        title = try container.decode(String.self, forKey: .title)
        clauses = try container.decodeIfPresent([PlannedClause].self, forKey: .clauses) ?? []
    }
}

/// One Definition of Done clause the author Act could not cite, dropped before it was written to the
/// board or the Journal (roadmap P9.5, second story) but recorded on the accepted plan so the drop is
/// auditable rather than silent.
public struct PlannedUncitableClause: Codable, Equatable, Sendable {
    public let level: String
    public let cardTitle: String?
    public let text: String
    public let citation: String
    public let reason: String

    public init(level: String, cardTitle: String?, text: String, citation: String, reason: String) {
        self.level = level
        self.cardTitle = cardTitle
        self.text = text
        self.citation = citation
        self.reason = reason
    }
}

/// One Card the plan adopts rather than replaces: the Journal row moves into the new Cycle at `order`.
public struct PlannedAdoption: Codable, Equatable, Sendable {
    public let key: String
    public let cardIssueID: String
    public let repository: String
    public let order: Int

    public init(key: String, cardIssueID: String, repository: String, order: Int) {
        self.key = key
        self.cardIssueID = cardIssueID
        self.repository = repository
        self.order = order
    }
}

/// The fields of a `featureAuthoringAccepted` event: everything needed to finalise the Journal rows
/// once the board has applied the group.
public struct FeatureAuthoringAcceptedPayload: Equatable, Sendable {
    public let name: String
    /// The Outbox group's key.
    public let groupKey: String
    /// The Outbox key of the Feature Issue's create; its entry's result is the Feature Issue's id.
    public let featureKey: String
    /// The Night whose selection this transaction authors — `feature.selected_night_id`.
    public let nightID: Int64
    public let cards: [PlannedCard]
    public let adoptions: [PlannedAdoption]
    /// The Feature Issue's citable Definition of Done clauses (roadmap P9.5); empty for a P9.4-era plan
    /// decoded from a legacy `featureAuthoringAccepted` event.
    public let featureClauses: [PlannedClause]
    /// Every clause dropped as uncitable, Feature and Card, recorded for audit (roadmap P9.5); empty for
    /// a P9.4-era plan.
    public let uncitableClauses: [PlannedUncitableClause]

    public init(
        name: String, groupKey: String, featureKey: String, nightID: Int64,
        cards: [PlannedCard], adoptions: [PlannedAdoption],
        featureClauses: [PlannedClause] = [], uncitableClauses: [PlannedUncitableClause] = []
    ) {
        self.name = name
        self.groupKey = groupKey
        self.featureKey = featureKey
        self.nightID = nightID
        self.cards = cards
        self.adoptions = adoptions
        self.featureClauses = featureClauses
        self.uncitableClauses = uncitableClauses
    }
}

/// The fields of a `featureAuthored` event.
public struct FeatureAuthoredPayload: Equatable, Sendable {
    public let name: String
    public let groupKey: String
    public let featureIssueID: String
    public let cycleID: Int64
    public let cardCount: Int
    public let adoptedCount: Int

    public init(
        name: String, groupKey: String, featureIssueID: String, cycleID: Int64, cardCount: Int, adoptedCount: Int
    ) {
        self.name = name
        self.groupKey = groupKey
        self.featureIssueID = featureIssueID
        self.cycleID = cycleID
        self.cardCount = cardCount
        self.adoptedCount = adoptedCount
    }
}

extension FeatureAuthoringAcceptedPayload {
    /// The event's flat string payload; the plan's lists are JSON so their shape survives any text.
    var eventPayload: [String: String] {
        [
            "name": name, "group_key": groupKey, "feature_key": featureKey, "night_id": String(nightID),
            "cards": Self.json(cards), "adoptions": Self.json(adoptions),
            "feature_clauses": Self.json(featureClauses), "uncitable_clauses": Self.json(uncitableClauses)
        ]
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decode(_ reader: PayloadReader) throws -> FeatureAuthoringAcceptedPayload {
        let decoder = JSONDecoder()
        do {
            // "feature_clauses" and "uncitable_clauses" post-date P9.4: a legacy event carries neither
            // key, and decodes as if the plan minted no clauses at all.
            let featureClausesJSON = reader.payload?["feature_clauses"] ?? "[]"
            let uncitableClausesJSON = reader.payload?["uncitable_clauses"] ?? "[]"
            return FeatureAuthoringAcceptedPayload(
                name: try reader.require("name"),
                groupKey: try reader.require("group_key"),
                featureKey: try reader.require("feature_key"),
                nightID: try reader.int64("night_id"),
                cards: try decoder.decode([PlannedCard].self, from: Data(try reader.require("cards").utf8)),
                adoptions: try decoder.decode(
                    [PlannedAdoption].self, from: Data(try reader.require("adoptions").utf8)
                ),
                featureClauses: try decoder.decode([PlannedClause].self, from: Data(featureClausesJSON.utf8)),
                uncitableClauses: try decoder.decode(
                    [PlannedUncitableClause].self, from: Data(uncitableClausesJSON.utf8)
                )
            )
        } catch is DecodingError {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
    }
}
