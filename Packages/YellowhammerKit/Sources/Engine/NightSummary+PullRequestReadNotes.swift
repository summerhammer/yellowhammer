import Domain
import Foundation
import Journal

// The standing line's notes from the pull request read (spec: morning-report/write-the-night-summary
// `#unmerged-standing-line`; feature-authoring/select-the-next-feature `#pull-request-read`, "What it reports and
// never acts on"; OQ190 items 13 and 19; issue #714). Read from each pull request's last observed state in the
// Journal, never from Code Hosting. Reported only: none of them is a gate input.

extension NightSummary {
    /// The Feature Branches of `features`, per repository: the branches a pull request of a Feature above them can be
    /// merged into while it waits for them.
    static func lowerFeatureBranches(_ features: [UnmergedFeature]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for feature in features {
            for (repository, branch) in feature.branches {
                result[repository, default: []].insert(branch.rawValue)
            }
        }
        return result
    }

    /// `[closed without merge: <repo>]` for a pull request last observed closed without merging, and
    /// `[merged into <branch>, waiting for it: <repo>]` for one last observed merged into a lower Feature's branch
    /// (one of `lowerBranches`), sorted by repository. Only repositories in `unmergedRepositories` are noted: one
    /// with an Observed Merge leaves the Operator nothing to act on. A merged pull request whose head is not the
    /// repository's Pushed Tip is not reported (item 13): commits the Operator added before merging are the
    /// Operator's. Empty when there is nothing to note.
    static func pullRequestReadNotes(
        featureID: Int64, unmergedRepositories: [String], pushedTips: [String: String],
        lowerBranches: [String: Set<String>], journal: JournalStore
    ) throws -> [String] {
        let pullRequests = try journal.pullRequests(featureID: featureID)
        return unmergedRepositories.sorted().compactMap { repository in
            guard let pullRequest = pullRequests[repository] else { return nil }
            switch pullRequest.observedState {
            case .closedWithoutMerge:
                return "[closed without merge: \(repository)]"
            case .merged:
                guard let base = pullRequest.baseBranch, lowerBranches[repository]?.contains(base) == true,
                    let tip = pushedTips[repository], pullRequest.headCommit == tip
                else { return nil }
                return "[merged into \(base), waiting for it: \(repository)]"
            case .open, nil:
                return nil
            }
        }
    }
}
