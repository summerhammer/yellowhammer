import Foundation
import Journal

/// Clause order, shared by the pull request title's primary epic and the worker commit message's story.
enum ClauseOrder {
    /// The clauses in clause order: the order of their `<!-- yh:clause:<cid> -->` markers in the issue's
    /// description when one was read, with unmarked clauses after, and otherwise (or among the unmarked)
    /// numeric cid order (`c2` before `c10`). The Journal's own order is by creation time, which
    /// authoring gives every clause of an issue alike, so it is not used.
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
