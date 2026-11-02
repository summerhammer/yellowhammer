import Domain
import Foundation
import Journal

/// Tracks the baseline of a halted Feature Card's title and description outside the Managed Block and
/// `yh:feature-authoring` region (Halted Authoring Repair Ruling 2026-10-23, item 5; spec:
/// `feature-authoring/select-the-next-feature`, `#feature-dod-repair`).
enum HaltOtherTextBaseline {
    static let notReadSentence =
        "The Feature Card's other text changed during the halt and was not read as repair input, " +
        "and was left as written."

    static func baselineKey(_ issue: BoardObjectID) -> String {
        "feature-halt-other-text:\(issue.rawValue)"
    }

    /// Strips the Managed Block fence contents and the `yh:feature-authoring` region from `description`,
    /// and returns the title plus the remaining description.
    static func otherText(title: String, description: String?) -> String {
        let desc = description ?? ""
        var text: String
        switch ManagedBlockFence.parts(of: desc) {
        case .success(let parts):
            text = parts.preservedProse
        case .failure:
            text = desc
        }
        if let start = text.range(of: FeatureAuthoringProse.start),
           let end = text.range(of: FeatureAuthoringProse.end, options: .backwards),
           start.lowerBound <= end.upperBound {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return title + "\n" + text
    }

    static func hash(title: String, description: String?) -> String {
        ManagedBlockFence.sha256(otherText(title: title, description: description))
    }

    static func record(issue: BoardObjectID, context: ActContext) async throws {
        guard let board = context.board,
              let object = try await board.reading.issue(issue) else { return }
        let contentHash = hash(title: object.title, description: object.description)
        try context.journal.recordManagedBlockPosted(issueID: baselineKey(issue), hash: contentHash)
    }

    static func hasChanged(issue: BoardObjectID, context: ActContext) async throws -> Bool {
        guard let baseline = try context.journal.managedBlockLastPostedHash(issueID: baselineKey(issue)) else {
            return false
        }
        guard let board = context.board,
              let object = try await board.reading.issue(issue) else {
            return false
        }
        let currentHash = hash(title: object.title, description: object.description)
        return currentHash != baseline
    }
}
