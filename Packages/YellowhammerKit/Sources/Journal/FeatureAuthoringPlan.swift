import Foundation

// The durable plan of one authoring transaction (roadmap P9.4; spec: feature-authoring/
// author-the-cycle-and-card-dag). It is recorded in the same Journal transaction that accepts the
// transaction's Outbox group, so a resumed author Act finishes exactly what was planned.

/// One Card the plan creates: the Outbox key its create was accepted under, and the Journal row it
/// becomes once the board has applied it.
public struct PlannedCard: Codable, Equatable, Sendable {
    public let key: String
    public let repository: String
    public let kind: String
    public let order: Int
    public let title: String

    public init(key: String, repository: String, kind: String, order: Int, title: String) {
        self.key = key
        self.repository = repository
        self.kind = kind
        self.order = order
        self.title = title
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

    public init(
        name: String, groupKey: String, featureKey: String, nightID: Int64,
        cards: [PlannedCard], adoptions: [PlannedAdoption]
    ) {
        self.name = name
        self.groupKey = groupKey
        self.featureKey = featureKey
        self.nightID = nightID
        self.cards = cards
        self.adoptions = adoptions
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
            "cards": Self.json(cards), "adoptions": Self.json(adoptions)
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
            return FeatureAuthoringAcceptedPayload(
                name: try reader.require("name"),
                groupKey: try reader.require("group_key"),
                featureKey: try reader.require("feature_key"),
                nightID: try reader.int64("night_id"),
                cards: try decoder.decode([PlannedCard].self, from: Data(try reader.require("cards").utf8)),
                adoptions: try decoder.decode(
                    [PlannedAdoption].self, from: Data(try reader.require("adoptions").utf8)
                )
            )
        } catch is DecodingError {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
    }
}
