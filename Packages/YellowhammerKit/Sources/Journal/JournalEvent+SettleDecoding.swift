import Domain
import Foundation

// The settle gesture's own events' decode and payload helpers (roadmap P10.9), split out of
// JournalEvent+Decoding.swift and JournalEvent+Payload.swift to keep those files under the file
// length limit — the same reason the land Act's own live in JournalEvent+LandActDecoding.swift.

extension JournalEvent {
    static func decodeSettle(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        switch type {
        case .featureCompleted:
            try decodeFeatureCompleted(reader)
        default:
            try decodeFeatureReleased(reader)
        }
    }

    /// The payload of the settle gesture's own events, dispatched here so the exhaustive payload
    /// switch stays one line for both.
    var settlePayload: [String: String]? {
        featureCompletedPayload ?? featureReleasedPayload
    }

    var featureCompletedPayload: [String: String]? {
        guard case .featureCompleted(
            let cycleID, let featureIssueID, let carriedForward, let acceptedCards, let keptWorktrees
        ) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "carried_forward": carriedForward.joined(separator: "\u{1F}"),
            "accepted_cards": acceptedCards.joined(separator: "\u{1F}"),
            "kept_worktrees": keptWorktrees.joined(separator: "\u{1F}")
        ]
    }

    var featureReleasedPayload: [String: String]? {
        guard case .featureReleased(
            let cycleID, let featureIssueID, let carriedForward, let acceptedCards, let abandonedRepositories,
            let triagedNightID
        ) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "carried_forward": carriedForward.joined(separator: "\u{1F}"),
            "accepted_cards": acceptedCards.joined(separator: "\u{1F}"),
            "abandoned_repositories": abandonedRepositories.joined(separator: "\u{1F}"),
            "triaged_night_id": String(triagedNightID)
        ]
    }

    static func decodeFeatureCompleted(_ reader: PayloadReader) throws -> JournalEvent {
        let rawCarriedForward = try reader.require("carried_forward")
        let rawAcceptedCards = try reader.require("accepted_cards")
        let rawKept = try reader.require("kept_worktrees")
        return .featureCompleted(
            cycleID: try reader.int64("cycle_id"),
            featureIssueID: try reader.require("feature_issue_id"),
            carriedForward: rawCarriedForward.isEmpty ? [] : rawCarriedForward.components(separatedBy: "\u{1F}"),
            acceptedCards: rawAcceptedCards.isEmpty ? [] : rawAcceptedCards.components(separatedBy: "\u{1F}"),
            keptWorktrees: rawKept.isEmpty ? [] : rawKept.components(separatedBy: "\u{1F}")
        )
    }

    static func decodeFeatureReleased(_ reader: PayloadReader) throws -> JournalEvent {
        let rawCarriedForward = try reader.require("carried_forward")
        let rawAcceptedCards = try reader.require("accepted_cards")
        let rawAbandoned = try reader.require("abandoned_repositories")
        return .featureReleased(
            cycleID: try reader.int64("cycle_id"),
            featureIssueID: try reader.require("feature_issue_id"),
            carriedForward: rawCarriedForward.isEmpty ? [] : rawCarriedForward.components(separatedBy: "\u{1F}"),
            acceptedCards: rawAcceptedCards.isEmpty ? [] : rawAcceptedCards.components(separatedBy: "\u{1F}"),
            abandonedRepositories: rawAbandoned.isEmpty ? [] : rawAbandoned.components(separatedBy: "\u{1F}"),
            triagedNightID: try reader.int64("triaged_night_id")
        )
    }
}
