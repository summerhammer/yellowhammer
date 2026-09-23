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
        guard case .adoptionRefused(let cardID, let issueID, let nightID, let featureName, let staleBlocks) = self
        else {
            return nil
        }
        return [
            "card_id": String(cardID), "issue_id": issueID, "night_id": String(nightID),
            "feature_name": featureName, "stale_blocks": Self.json(staleBlocks)
        ]
    }

    var cardAdoptedPayload: [String: String]? {
        guard case .cardAdopted(
            let cardID, let issueID, let previousFeatureIssueID, let newFeatureIssueID, let priorBlockReason,
            let coldStartNote
        ) = self else {
            return nil
        }
        return [
            "card_id": String(cardID), "issue_id": issueID, "previous_feature_issue_id": previousFeatureIssueID,
            "new_feature_issue_id": newFeatureIssueID, "prior_block_reason": priorBlockReason ?? "",
            "cold_start_note": coldStartNote
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
        let decoder = JSONDecoder()
        let staleBlocks: [AdoptionStaleBlock]
        do {
            staleBlocks = try decoder.decode([AdoptionStaleBlock].self, from: Data(raw.utf8))
        } catch {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .adoptionRefused(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            nightID: try reader.int64("night_id"), featureName: try reader.require("feature_name"),
            staleBlocks: staleBlocks
        )
    }

    static func decodeCardAdopted(_ reader: PayloadReader) throws -> JournalEvent {
        let priorBlockReason = reader.payload?["prior_block_reason"]
        return .cardAdopted(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            previousFeatureIssueID: try reader.require("previous_feature_issue_id"),
            newFeatureIssueID: try reader.require("new_feature_issue_id"),
            priorBlockReason: (priorBlockReason?.isEmpty ?? true) ? nil : priorBlockReason,
            coldStartNote: try reader.require("cold_start_note")
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

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
