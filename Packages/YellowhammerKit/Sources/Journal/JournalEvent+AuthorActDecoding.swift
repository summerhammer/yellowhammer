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
}
