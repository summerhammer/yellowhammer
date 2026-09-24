import Domain
import Foundation

// Explicit Project removal's own event (roadmap P13.5; spec risks OQ52(1)), split out of
// JournalEvent+Decoding.swift and JournalEvent+Payload.swift to keep those files under the file length
// limit — the same reason the settle gesture's own live in JournalEvent+SettleDecoding.swift.

extension JournalEvent {
    var projectRemovedPayload: [String: String]? {
        guard case .projectRemoved(let featureIssueID, let removedWorktrees, let keptWorktrees) = self else {
            return nil
        }
        var dict: [String: String] = [
            "removed_worktrees": removedWorktrees.joined(separator: "\u{1F}"),
            "kept_worktrees": keptWorktrees.joined(separator: "\u{1F}")
        ]
        if let featureIssueID {
            dict["feature_issue_id"] = featureIssueID
        }
        return dict
    }

    static func decodeProjectRemoved(_ reader: PayloadReader) throws -> JournalEvent {
        let rawRemoved = try reader.require("removed_worktrees")
        let rawKept = try reader.require("kept_worktrees")
        return .projectRemoved(
            featureIssueID: reader.payload?["feature_issue_id"],
            removedWorktrees: rawRemoved.isEmpty ? [] : rawRemoved.components(separatedBy: "\u{1F}"),
            keptWorktrees: rawKept.isEmpty ? [] : rawKept.components(separatedBy: "\u{1F}")
        )
    }
}
