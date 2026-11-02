import Domain
import Foundation
import Journal

/// Tracks a halted Feature Card's title and its prose outside the Managed Block and editable Definition
/// of Done section (Halted Authoring Repair Ruling 2026-10-23, item 5; spec:
/// `feature-authoring/select-the-next-feature`, `#feature-dod-repair`).
enum HaltOtherTextBaseline {
    static let notReadSentence =
        "The Feature Card's other text changed during the halt and was not read as repair input, " +
        "and was left as written."

    static func baselineKey(_ issue: BoardObjectID) -> String {
        "feature-halt-other-text:\(issue.rawValue)"
    }

    /// Strips the Managed Block and editable Definition of Done, retaining other authored-region prose
    /// as well as text outside that region. The engine-owned draft headline does not count as an edit.
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
            if var region = FeatureAuthoringProse.current(in: desc) {
                if let range = FeatureDefinitionOfDone.sectionRange(in: region) { region.removeSubrange(range) }
                region = region.replacingOccurrences(of: HaltDrafts.featureHeadline, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !region.isEmpty { text += "\n" + region }
            }
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
