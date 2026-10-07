import Domain
import Foundation
import Journal

// The Night Summary's line for a Feature Branch the ghost-Worktree purge could not recover (OQ133). It
// renders inside `**Exceptions:**`: Orca ADE deleted the branch on the Operator's own removal of the
// Worktree, Yellowhammer destroyed nothing, but the Operator is owed the news that commits are gone.

extension NightSummary {
    /// One line per `worktreeLost` this Night that recovered nothing and lost something: the
    /// (Feature, repository), the lost tip and the Done Work Cards whose commits are gone. A purge that
    /// pinned a commit, or whose lane held nothing worth naming (nothing recorded, work already pushed),
    /// renders no line. Empty when none happened this Night.
    static func worktreeLossLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for record in try nightEvents(night: night, journal: journal) {
            guard case .worktreeLost(
                let featureID, let repository, _, _, nil, let lostCommit, let lostDoneCardIDs
            ) = record.event, lostCommit != nil || !lostDoneCardIDs.isEmpty else { continue }
            let feature = try journal.feature(id: featureID).map { "`\($0.issueID)`" } ?? "#\(featureID)"
            let tip = lostCommit.map { "`\($0)` is gone from the repository" } ?? "none was recorded"
            let cards = try lostDoneCardIDs.map { "`\(try journal.card(id: $0).issueID)`" }
            let affected = cards.isEmpty
                ? "No Done Work Card is affected."
                : "Done Work Cards whose commits are gone: \(cards.joined(separator: ", ")). " +
                    "Re-readying them is the Operator's gesture."
            lines.append(
                "Feature \(feature)'s Worktree in `\(repository)` was removed outside Yellowhammer, taking its " +
                    "Feature Branch, and nothing could be recovered. Last known-good commit: \(tip). \(affected)"
            )
        }
        return lines
    }
}
