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
                unmet: try reader.int("unmet"), unresolved: try reader.int("unresolved"),
                notChecked: try reader.optionalInt("not_checked", default: 0)
            )
        case .featureReturned:
            .featureReturned(
                cycleID: try reader.int64("cycle_id"), featureIssueID: try reader.require("feature_issue_id"),
                unmet: try reader.int("unmet"), unresolved: try reader.int("unresolved"),
                notChecked: try reader.optionalInt("not_checked", default: 0)
            )
        case .cycleArchived:
            try decodeCycleArchived(reader)
        case .noPushedBranchOutcome:
            .noPushedBranchOutcome(
                cycleID: try reader.int64("cycle_id"), featureIssueID: try reader.require("feature_issue_id"),
                repository: try reader.require("repository")
            )
        case .landedPinFailed:
            .landedPinFailed(
                featureIssueID: try reader.require("feature_issue_id"), repository: try reader.require("repository"),
                branch: try reader.require("branch"), commit: try reader.require("commit"),
                operation: try reader.landedPinOperation("operation"), reason: try reader.require("reason")
            )
        case .pullRequestStacked:
            .pullRequestStacked(
                featureIssueID: try reader.require("feature_issue_id"), repository: try reader.require("repository"),
                predecessorFeatureIssueID: try reader.require("predecessor_feature_issue_id"),
                predecessorBranch: try reader.require("predecessor_branch"),
                predecessorPullRequestURL: reader.payload?["predecessor_pull_request_url"]
            )
        case .featureClosedByMerge:
            try decodeFeatureClosedByMerge(reader)
        case .verifiedFeatureMergeObserved:
            try decodeVerifiedFeatureMergeObserved(reader)
        case .completedFeatureMergeObserved:
            try decodeCompletedFeatureMergeObserved(reader)
        default:
            try decodeLandStep(reader)
        }
    }

    /// The payload of the events that close out a landed Cycle — Verification, return, archival and
    /// closure by merge — dispatched here so the exhaustive payload switch stays one line for all four.
    var landActPayload: [String: String]? {
        featureVerifiedPayload ?? featureReturnedPayload ?? cycleArchivedPayload ?? featureClosedByMergePayload
            ?? verifiedFeatureMergeObservedPayload ?? completedFeatureMergeObservedPayload
            ?? noPushedBranchOutcomePayload ?? landedPinFailedPayload ?? pullRequestStackedPayload
    }

    /// The `pullRequestStacked` event's payload; `predecessor_pull_request_url` is absent when nil.
    var pullRequestStackedPayload: [String: String]? {
        guard case .pullRequestStacked(
            let featureIssueID, let repository, let predecessorFeatureIssueID, let predecessorBranch,
            let predecessorPullRequestURL
        ) = self else {
            return nil
        }
        var payload = [
            "feature_issue_id": featureIssueID, "repository": repository,
            "predecessor_feature_issue_id": predecessorFeatureIssueID, "predecessor_branch": predecessorBranch
        ]
        payload["predecessor_pull_request_url"] = predecessorPullRequestURL
        return payload
    }

    /// The `landedPinFailed` event's payload.
    var landedPinFailedPayload: [String: String]? {
        guard case .landedPinFailed(
            let featureIssueID, let repository, let branch, let commit, let operation, let reason
        ) = self else {
            return nil
        }
        return [
            "feature_issue_id": featureIssueID, "repository": repository, "branch": branch, "commit": commit,
            "operation": operation.rawValue, "reason": reason
        ]
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

    /// The `verifiedFeatureMergeObserved` event's payload (issue #447).
    var verifiedFeatureMergeObservedPayload: [String: String]? {
        guard case .verifiedFeatureMergeObserved(
            let cycleID, let featureIssueID, let repositories, let acceptedCards, let triagedNightID
        ) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "repositories": repositories.joined(separator: "\u{1F}"),
            "accepted_cards": acceptedCards.joined(separator: "\u{1F}"),
            "triaged_night_id": String(triagedNightID)
        ]
    }

    /// The `completedFeatureMergeObserved` event's payload: the same keys as the verified one.
    var completedFeatureMergeObservedPayload: [String: String]? {
        guard case .completedFeatureMergeObserved(
            let cycleID, let featureIssueID, let repositories, let acceptedCards, let triagedNightID
        ) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "repositories": repositories.joined(separator: "\u{1F}"),
            "accepted_cards": acceptedCards.joined(separator: "\u{1F}"),
            "triaged_night_id": String(triagedNightID)
        ]
    }

    /// The `featureVerified` event's payload: counts only.
    var featureVerifiedPayload: [String: String]? {
        guard case .featureVerified(let cycleID, let met, let unmet, let unresolved, let notChecked) = self else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "met": String(met), "unmet": String(unmet), "unresolved": String(unresolved),
            "not_checked": String(notChecked)
        ]
    }

    /// The `featureReturned` event's payload: the Feature Issue id and counts only — the per-clause
    /// detail is in the return comment, not the Journal.
    var featureReturnedPayload: [String: String]? {
        guard case .featureReturned(let cycleID, let featureIssueID, let unmet, let unresolved, let notChecked) = self
        else {
            return nil
        }
        return [
            "cycle_id": String(cycleID), "feature_issue_id": featureIssueID,
            "unmet": String(unmet), "unresolved": String(unresolved),
            "not_checked": String(notChecked)
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

    static func decodeVerifiedFeatureMergeObserved(_ reader: PayloadReader) throws -> JournalEvent {
        let rawRepositories = try reader.require("repositories")
        let rawAcceptedCards = try reader.require("accepted_cards")
        return .verifiedFeatureMergeObserved(
            cycleID: try reader.int64("cycle_id"),
            featureIssueID: try reader.require("feature_issue_id"),
            repositories: rawRepositories.isEmpty ? [] : rawRepositories.components(separatedBy: "\u{1F}"),
            acceptedCards: rawAcceptedCards.isEmpty ? [] : rawAcceptedCards.components(separatedBy: "\u{1F}"),
            triagedNightID: try reader.int64("triaged_night_id")
        )
    }

    static func decodeCompletedFeatureMergeObserved(_ reader: PayloadReader) throws -> JournalEvent {
        let rawRepositories = try reader.require("repositories")
        let rawAcceptedCards = try reader.require("accepted_cards")
        return .completedFeatureMergeObserved(
            cycleID: try reader.int64("cycle_id"),
            featureIssueID: try reader.require("feature_issue_id"),
            repositories: rawRepositories.isEmpty ? [] : rawRepositories.components(separatedBy: "\u{1F}"),
            acceptedCards: rawAcceptedCards.isEmpty ? [] : rawAcceptedCards.components(separatedBy: "\u{1F}"),
            triagedNightID: try reader.int64("triaged_night_id")
        )
    }
}
