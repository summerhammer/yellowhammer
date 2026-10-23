import Domain
import Foundation

// The payload and decode of `adoptionRefused` and `cardAdopted` (roadmap P11.5; spec: feature-authoring/
// author-the-cycle-and-card-dag, second story), split out of JournalEvent+Payload.swift and
// JournalEvent+Decoding.swift to keep those files under the file length limit, as the unanswered-Nights
// clock's event is split into its own file too.

/// One repository's stale paths, recorded on an `adoptionRefused` event (roadmap P11.5).
public struct AdoptionStaleBlock: Codable, Equatable, Sendable {
    public let repository: String
    public let changedPaths: [String]

    public init(repository: String, changedPaths: [String]) {
        self.repository = repository
        self.changedPaths = changedPaths
    }
}

/// One earlier same-repository sequence member absent from an Adoption, recorded on an `adoptionRefused`
/// event (spec ruling OQ182, item 6): named by title and repository for the Managed Block's notice.
public struct AbsentEarlierSequenceMember: Codable, Equatable, Sendable {
    public let title: String
    public let repository: String

    public init(title: String, repository: String) {
        self.title = title
        self.repository = repository
    }
}

/// What an `adoptionRefused` event's `stale_blocks` payload key holds: either reason a refusal fires
/// (spec ruling OQ182, item 6, is a sibling of the stale-provenance refusal, never both at once in
/// practice, but the shape allows either or neither). Encoded as a JSON object in the same key a
/// Journal written before this change held a bare `[AdoptionStaleBlock]` array in — ``decodeLenient(_:)``
/// reads both shapes, so this needed no schema change.
struct AdoptionRefusalDetails: Codable, Equatable, Sendable {
    var staleBlocks: [AdoptionStaleBlock]
    var absentEarlierSequenceMembers: [AbsentEarlierSequenceMember]

    init(staleBlocks: [AdoptionStaleBlock] = [], absentEarlierSequenceMembers: [AbsentEarlierSequenceMember] = []) {
        self.staleBlocks = staleBlocks
        self.absentEarlierSequenceMembers = absentEarlierSequenceMembers
    }

    /// Decodes either this type's own object shape, or the bare `[AdoptionStaleBlock]` array a Journal
    /// written before this change recorded; nil when neither parses.
    static func decodeLenient(_ raw: String) -> AdoptionRefusalDetails? {
        let decoder = JSONDecoder()
        let data = Data(raw.utf8)
        if let details = try? decoder.decode(AdoptionRefusalDetails.self, from: data) {
            return details
        }
        if let legacy = try? decoder.decode([AdoptionStaleBlock].self, from: data) {
            return AdoptionRefusalDetails(staleBlocks: legacy)
        }
        return nil
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension JournalEvent {
    /// Dispatches to whichever of the three Adoption events `self` is; merged into one switch case in
    /// JournalEvent+Payload.swift's own switch, to keep that file under the file length limit.
    var adoptionEventPayload: [String: String]? {
        switch self {
        case .adoptionRefused: adoptionRefusedPayload
        case .cardAdopted: cardAdoptedPayload
        case .adoptionUntestable: adoptionUntestablePayload
        default: nil
        }
    }

    var adoptionRefusedPayload: [String: String]? {
        guard case .adoptionRefused(
            let cardID, let issueID, let nightID, let featureName, let staleBlocks, let absentEarlierSequenceMembers
        ) = self else {
            return nil
        }
        let details = AdoptionRefusalDetails(
            staleBlocks: staleBlocks, absentEarlierSequenceMembers: absentEarlierSequenceMembers
        )
        return [
            "card_id": String(cardID), "issue_id": issueID, "night_id": String(nightID),
            "feature_name": featureName, "stale_blocks": details.encoded()
        ]
    }

    var cardAdoptedPayload: [String: String]? {
        guard case .cardAdopted(
            let cardID, let issueID, let previousFeatureIssueID, let newFeatureIssueID, let priorBlockReason,
            let coldStartNote, let previousAuthoredOrder
        ) = self else {
            return nil
        }
        return [
            "card_id": String(cardID), "issue_id": issueID, "previous_feature_issue_id": previousFeatureIssueID,
            "new_feature_issue_id": newFeatureIssueID, "prior_block_reason": priorBlockReason ?? "",
            "cold_start_note": coldStartNote,
            "previous_authored_order": previousAuthoredOrder.map(String.init) ?? ""
        ]
    }

    /// Dispatches to whichever of the three Adoption events `type` names; merged into one switch case
    /// in JournalEvent+Decoding.swift's own switch, to keep that file under the file length limit.
    static func decodeAdoptionEvent(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        switch type {
        case .adoptionRefused: try decodeAdoptionRefused(reader)
        case .cardAdopted: try decodeCardAdopted(reader)
        case .adoptionUntestable: try decodeAdoptionUntestable(reader)
        default: throw JournalError.eventUnreadable(id: reader.rowID)
        }
    }

    static func decodeAdoptionRefused(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = reader.payload?["stale_blocks"] ?? "[]"
        guard let details = AdoptionRefusalDetails.decodeLenient(raw) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .adoptionRefused(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            nightID: try reader.int64("night_id"), featureName: try reader.require("feature_name"),
            staleBlocks: details.staleBlocks, absentEarlierSequenceMembers: details.absentEarlierSequenceMembers
        )
    }

    static func decodeCardAdopted(_ reader: PayloadReader) throws -> JournalEvent {
        let priorBlockReason = reader.payload?["prior_block_reason"]
        let rawPreviousAuthoredOrder = reader.payload?["previous_authored_order"]
        let previousAuthoredOrder = (rawPreviousAuthoredOrder?.isEmpty ?? true)
            ? nil : rawPreviousAuthoredOrder.flatMap(Int.init)
        return .cardAdopted(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            previousFeatureIssueID: try reader.require("previous_feature_issue_id"),
            newFeatureIssueID: try reader.require("new_feature_issue_id"),
            priorBlockReason: (priorBlockReason?.isEmpty ?? true) ? nil : priorBlockReason,
            coldStartNote: try reader.require("cold_start_note"), previousAuthoredOrder: previousAuthoredOrder
        )
    }

    var adoptionUntestablePayload: [String: String]? {
        guard case .adoptionUntestable(let cardID, let issueID, let featureName, let reasons) = self else {
            return nil
        }
        return [
            "card_id": String(cardID), "issue_id": issueID, "feature_name": featureName,
            "reasons": reasons.joined(separator: "\u{1F}")
        ]
    }

    static func decodeAdoptionUntestable(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("reasons")
        let reasons = raw.isEmpty ? [] : raw.components(separatedBy: "\u{1F}")
        return .adoptionUntestable(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            featureName: try reader.require("feature_name"), reasons: reasons
        )
    }
}
