import Domain
import Foundation

// The author Act's own events' decode helpers, split out of JournalEvent+Decoding.swift (whose
// exhaustive switch still dispatches to them) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeObservedReleaseRecorded(_ reader: PayloadReader) throws -> JournalEvent {
        .observedReleaseRecorded(
            featureIssueID: try reader.require("feature_issue_id"), repository: try reader.require("repository"),
            tagName: try reader.require("tag_name"), tagCommit: try reader.require("tag_commit")
        )
    }

    static func decodeAuthoringReleaseGateHeld(_ reader: PayloadReader) throws -> JournalEvent {
        guard let hold = ConsumerHold(rawValue: try reader.require("hold")) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .authoringReleaseGateHeld(
            featureName: try reader.require("feature_name"), consumer: try reader.require("consumer"),
            producer: try reader.require("producer"),
            producerFeatureIssueID: try reader.require("producer_feature_issue_id"), hold: hold
        )
    }

    static func decodeAuthoringSkippedUnmergedStackFull(_ reader: PayloadReader) throws -> JournalEvent {
        let features: [UnmergedStackEntry]
        do {
            features = try JSONDecoder().decode(
                [UnmergedStackEntry].self, from: Data(try reader.require("features").utf8)
            )
        } catch {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .authoringSkippedUnmergedStackFull(
            features: features, unmergedFeaturesMax: try reader.int("unmerged_features_max")
        )
    }

    /// The Unmerged Feature Stack entries as sorted-keys JSON, so the stored payload is byte-stable.
    static func stackEntriesJSON(_ features: [UnmergedStackEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(features)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeAuthoringPredecessorIndeterminate(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("repositories")
        let repositories = raw.isEmpty ? [] : raw.components(separatedBy: "\u{1F}")
        return .authoringPredecessorIndeterminate(
            featureIssueID: try reader.require("feature_issue_id"),
            repositories: repositories
        )
    }

    static func decodePredecessorAncestryObserved(_ reader: PayloadReader) throws -> JournalEvent {
        let rawMerged = try reader.require("merged_repositories")
        let rawUnmerged = try reader.require("unmerged_repositories")
        return .predecessorAncestryObserved(
            featureIssueID: try reader.require("feature_issue_id"),
            mergedRepositories: rawMerged.isEmpty ? [] : rawMerged.components(separatedBy: "\u{1F}"),
            unmergedRepositories: rawUnmerged.isEmpty ? [] : rawUnmerged.components(separatedBy: "\u{1F}")
        )
    }

    static func decodeMainlineConflictDetected(_ reader: PayloadReader) throws -> JournalEvent {
        let rawPaths = try reader.require("paths")
        return .mainlineConflictDetected(
            featureIssueID: try reader.require("feature_issue_id"),
            repository: try reader.require("repository"),
            paths: rawPaths.isEmpty ? [] : rawPaths.components(separatedBy: "\u{1F}")
        )
    }

    static func decodeFeatureSelected(_ reader: PayloadReader) throws -> JournalEvent {
        let rawRepositories = try reader.require("repositories")
        let rawAdopted = try reader.require("adopted_card_issue_ids")
        let rawUnadopted = try reader.require("unadopted_card_issue_ids")
        let payload = FeatureSelectedPayload(
            name: try reader.require("name"),
            reasoning: try reader.require("reasoning"),
            precededBy: reader.payload?["preceded_by"],
            followedBy: reader.payload?["followed_by"],
            seam: reader.payload?["seam"],
            repositories: rawRepositories.isEmpty ? [] : rawRepositories.components(separatedBy: "\u{1F}"),
            adoptedCardIssueIDs: rawAdopted.isEmpty ? [] : rawAdopted.components(separatedBy: "\u{1F}"),
            unadoptedCardIssueIDs: rawUnadopted.isEmpty ? [] : rawUnadopted.components(separatedBy: "\u{1F}")
        )
        return .featureSelected(payload)
    }

    static func decodeFeatureAuthored(_ reader: PayloadReader) throws -> JournalEvent {
        .featureAuthored(FeatureAuthoredPayload(
            name: try reader.require("name"),
            groupKey: try reader.require("group_key"),
            featureIssueID: try reader.require("feature_issue_id"),
            cycleID: try reader.int64("cycle_id"),
            cardCount: try reader.int("card_count"),
            adoptedCount: try reader.int("adopted_count")
        ))
    }
}
