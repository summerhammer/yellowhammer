import Domain
import Foundation

// The author Act's own events' decode helpers, split out of JournalEvent+Decoding.swift (whose
// exhaustive switch still dispatches to them) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeAuthoringPredecessorNotLanded(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("repositories")
        let repositories = raw.isEmpty ? [] : raw.components(separatedBy: "\u{1F}")
        return .authoringPredecessorNotLanded(
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
}
