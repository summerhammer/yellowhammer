import Domain
import Foundation

// The land Act's own event's decode helper, split out of JournalEvent+Decoding.swift (whose
// exhaustive switch still dispatches to it) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeLandAct(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        switch type {
        case .featureVerified:
            .featureVerified(
                cycleID: try reader.int64("cycle_id"), met: try reader.int("met"),
                unmet: try reader.int("unmet"), unresolved: try reader.int("unresolved")
            )
        case .featureReturned:
            .featureReturned(
                cycleID: try reader.int64("cycle_id"), featureIssueID: try reader.require("feature_issue_id"),
                unmet: try reader.int("unmet"), unresolved: try reader.int("unresolved")
            )
        case .cycleArchived:
            try decodeCycleArchived(reader)
        case .noPushedBranchOutcome:
            .noPushedBranchOutcome(
                cycleID: try reader.int64("cycle_id"), featureIssueID: try reader.require("feature_issue_id"),
                repository: try reader.require("repository")
            )
        case .featureClosedByMerge:
            try decodeFeatureClosedByMerge(reader)
        default:
            try decodeLandStep(reader)
        }
    }

    /// The payload of the events that close out a landed Cycle — Verification, return, archival and
    /// closure by merge — dispatched here so the exhaustive payload switch stays one line for all four.
    var landActPayload: [String: String]? {
        featureVerifiedPayload ?? featureReturnedPayload ?? cycleArchivedPayload ?? featureClosedByMergePayload
            ?? noPushedBranchOutcomePayload
    }

    /// The `noPushedBranchOutcome` event's payload.
    var noPushedBranchOutcomePayload: [String: String]? {
        guard case .noPushedBranchOutcome(let cycleID, let featureIssueID, let repository) = self else { return nil }
        return ["cycle_id": String(cycleID), "feature_issue_id": featureIssueID, "repository": repository]
    }

    /// The `featureClosedByMerge` event's payload (roadmap P10.8).
    var featureClosedByMergePayload: [String: String]? {
        guard case .featureClosedByMerge(
            let cycleID, let featureIssueID, let repositories, let carriedForward, let acceptedCards,
            let triagedNightID
        ) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "repositories": repositories.joined(separator: "\u{1F}"),
            "carried_forward": carriedForward.joined(separator: "\u{1F}"),
            "accepted_cards": acceptedCards.joined(separator: "\u{1F}"),
            "triaged_night_id": String(triagedNightID)
        ]
    }

    /// The `featureVerified` event's payload: counts only.
    var featureVerifiedPayload: [String: String]? {
        guard case .featureVerified(let cycleID, let met, let unmet, let unresolved) = self else { return nil }
        return [
            "cycle_id": String(cycleID), "met": String(met), "unmet": String(unmet), "unresolved": String(unresolved)
        ]
    }

    /// The `featureReturned` event's payload: the Feature Issue id and counts only — the per-clause
    /// detail is in the return comment, not the Journal.
    var featureReturnedPayload: [String: String]? {
        guard case .featureReturned(let cycleID, let featureIssueID, let unmet, let unresolved) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "unmet": String(unmet), "unresolved": String(unresolved)
        ]
    }

    /// The `cycleArchived` event's payload: the Feature Issue id, which route closed it, and how many
    /// Blocked Cards were detached in the same pass.
    var cycleArchivedPayload: [String: String]? {
        guard case .cycleArchived(let cycleID, let featureIssueID, let closedBy, let detachedCards) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID, "closed_by": closedBy.rawValue,
            "detached_cards": String(detachedCards)
        ]
    }

    static func decodeCycleArchived(_ reader: PayloadReader) throws -> JournalEvent {
        .cycleArchived(
            cycleID: try reader.int64("cycle_id"), featureIssueID: try reader.require("feature_issue_id"),
            closedBy: try reader.featureClosure("closed_by"), detachedCards: try reader.int("detached_cards")
        )
    }

    static func decodeLandStep(_ reader: PayloadReader) throws -> JournalEvent {
        .landStep(
            step: try reader.landStep("step"),
            repository: reader.payload?["repository"],
            outcome: try reader.landStepOutcome("outcome"),
            detail: reader.payload?["detail"]
        )
    }

    static func decodeFeatureClosedByMerge(_ reader: PayloadReader) throws -> JournalEvent {
        let rawRepositories = try reader.require("repositories")
        let rawCarriedForward = try reader.require("carried_forward")
        let rawAcceptedCards = try reader.require("accepted_cards")
        return .featureClosedByMerge(
            cycleID: try reader.int64("cycle_id"),
            featureIssueID: try reader.require("feature_issue_id"),
            repositories: rawRepositories.isEmpty ? [] : rawRepositories.components(separatedBy: "\u{1F}"),
            carriedForward: rawCarriedForward.isEmpty ? [] : rawCarriedForward.components(separatedBy: "\u{1F}"),
            acceptedCards: rawAcceptedCards.isEmpty ? [] : rawAcceptedCards.components(separatedBy: "\u{1F}"),
            triagedNightID: try reader.int64("triaged_night_id")
        )
    }
}
