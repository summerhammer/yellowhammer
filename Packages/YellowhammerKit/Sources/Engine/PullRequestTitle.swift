import Domain
import Foundation
import Journal

/// The land Act's pull request title (roadmap P19.2): the Project's `pull_request_title` Message
/// Template rendered with this pull request's token values. Pure; the seam fetches the inputs.
enum PullRequestTitle {
    /// What fills the template's tokens. `featureKey` is the Feature Issue's human identifier and is
    /// empty when the board object was unavailable (never Linear's opaque id).
    struct Inputs: Equatable {
        var featureTitle: String
        var featureKey: String
        var repository: String
        var branch: String
        var projectID: String
        var isPartialLanding: Bool
        var primaryEpic: String?
    }

    static let partialLandingPrefix = "partial landing: "

    static func render(template: MessageTemplate, changeType: ChangeType, inputs: Inputs) -> String {
        template.render([
            .type: changeType.rawValue,
            .title: inputs.featureTitle,
            .key: inputs.featureKey,
            .repository: inputs.repository,
            .branch: inputs.branch,
            .project: inputs.projectID,
            .partial: inputs.isPartialLanding ? partialLandingPrefix : "",
            .scope: inputs.primaryEpic.map { "(\($0))" } ?? ""
        ])
    }

    /// The Feature's primary epic: the epic cited by the most Feature-level clauses, counting one per
    /// clause whose citation is a story ID (goal IDs and anchors are ignored). On a tie, the tied epic
    /// whose earliest story-citing clause comes first wins. `citations` is in clause order. Nil when no
    /// clause cites a story ID.
    static func primaryEpic(citations: [SpecCitation]) -> String? {
        var counts: [String: Int] = [:]
        var firstIndex: [String: Int] = [:]
        for (index, citation) in citations.enumerated() {
            guard let epic = citation.epic else { continue }
            counts[epic, default: 0] += 1
            if firstIndex[epic] == nil { firstIndex[epic] = index }
        }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return (firstIndex[lhs.key] ?? 0) > (firstIndex[rhs.key] ?? 0)
        }?.key
    }

    /// The Feature-level clauses in clause order: the order of their `<!-- yh:clause:<cid> -->` markers
    /// in the Feature Issue's description when one was read, with unmarked clauses after, and otherwise
    /// (or among the unmarked) numeric cid order (`c2` before `c10`). The Journal's own order is by
    /// creation time, which authoring gives every clause of a Feature alike, so it is not used.
    static func inClauseOrder(_ clauses: [ClauseRecord], description: String?) -> [ClauseRecord] {
        func number(_ clause: ClauseRecord) -> Int {
            Int(clause.cid.dropFirst()) ?? Int.max
        }
        func position(_ clause: ClauseRecord) -> Int? {
            guard let description,
                let range = description.range(of: "<!-- yh:clause:\(clause.cid) -->")
            else { return nil }
            return description.distance(from: description.startIndex, to: range.lowerBound)
        }
        return clauses
            .map { (clause: $0, position: position($0)) }
            .sorted { lhs, rhs in
                switch (lhs.position, rhs.position) {
                case let (left?, right?) where left != right: return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    let (leftNumber, rightNumber) = (number(lhs.clause), number(rhs.clause))
                    if leftNumber != rightNumber { return leftNumber < rightNumber }
                    return lhs.clause.cid < rhs.clause.cid
                }
            }
            .map(\.clause)
    }
}
