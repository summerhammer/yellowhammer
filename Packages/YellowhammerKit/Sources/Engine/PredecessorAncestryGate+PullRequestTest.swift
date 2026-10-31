import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's pull request test, the merge test's second rung (spec: feature-authoring/
// select-the-next-feature, #merge-test, #pull-request-read; OQ190 items 8, 9, 10, 22, 23, 26, 27 and 28): for a
// repository whose tip is not an ancestor of mainline, the Feature's pull request there, as the pass's pull request
// read found it (PredecessorAncestryGate+PullRequestRead.swift). It holds when the pull request reads merged and its
// merge commit is an ancestor of the fetched mainline, checked locally. A read only ever adds evidence: a pull
// request read open or closed, or a read that cannot be made, leaves the repository to the content test. Split out
// of PredecessorAncestryGate+MergeTest.swift for the file and type length limits.

extension PredecessorAncestryGate {
    /// Runs the pull request test on each repository with no Observed Merge by ancestry (its tip not an ancestor of
    /// mainline, or an ancestor whose landing commit could not be read), records the Observed Merge (evidence
    /// `pull_request`, the merge commit as its landing commit) for each where it holds, and returns the rest, in
    /// order. A repository the pass did not read is returned as it is.
    func testPullRequests(
        of notAncestors: [RepoAncestryResult], scope: TestScope, into result: inout AncestryTestResult
    ) async throws -> [RepoAncestryResult] {
        guard !scope.pullRequestReads.isEmpty, !notAncestors.isEmpty else { return notAncestors }
        var remaining: [RepoAncestryResult] = []
        for notAncestor in notAncestors {
            if let merge = await pullRequestMerge(of: notAncestor, scope: scope) {
                try await recordObservedMerge(merge, scope: scope)
                result.merged.append(notAncestor.repository)
            } else {
                remaining.append(notAncestor)
            }
        }
        return remaining
    }

    /// The Observed Merge the pull request test finds in one repository, or nil when it does not hold or cannot run.
    /// It cannot run without the tested commit and mainline's commit, or where the pass made no read there.
    private func pullRequestMerge(of notAncestor: RepoAncestryResult, scope: TestScope) async -> ObservedMerge? {
        guard
            let tipCommit = notAncestor.branchCommit,
            let mainlineCommit = notAncestor.mainlineCommit, !mainlineCommit.isEmpty,
            let repo = scope.repos.first(where: { $0.name == notAncestor.repository }),
            let mergeCommit = Self.mergeCommitUnderTest(scope.pullRequestReads[repo.name])
        else { return nil }

        // Item 9 and 23: merged into any branch, but it counts only once its merge commit is in mainline, as this
        // clone has it. A merge commit the clone does not have reads as not in mainline.
        let path = (repo.path as NSString).expandingTildeInPath
        guard await ancestryTester.isAncestor(ancestorCommitOrRef: mergeCommit, of: mainlineCommit, in: path) else {
            return nil
        }
        return ObservedMerge(
            repository: repo.name, landingCommit: mergeCommit, mainlineCommit: mainlineCommit, tipCommit: tipCommit,
            evidence: .pullRequest
        )
    }

    /// The merge commit of the pull request under test, when it reads merged: from this pass's read, which chose it
    /// against the tested tip, or the one an earlier read recorded with the merged state, final for that pull
    /// request and still carrying the tip. Nil otherwise.
    static func mergeCommitUnderTest(_ reading: PullRequestReading?) -> String? {
        switch reading {
        case .read(let pullRequest):
            return pullRequest?.state == .merged ? pullRequest?.mergeCommit : nil
        case .recordedMerge(let mergeCommit):
            return mergeCommit
        case .failed, nil:
            return nil
        }
    }
}
