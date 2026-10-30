import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's pull request test, the merge test's second rung (spec: feature-authoring/
// select-the-next-feature, #merge-test, #pull-request-read; OQ190 items 8, 9, 10, 22, 23, 26, 27 and 28): for a
// repository whose tip is not an ancestor of mainline, the Feature's pull request there is read through the
// Publication Port. It holds when the pull request reads merged and its merge commit is an ancestor of the fetched
// mainline, checked locally. A read only ever adds evidence: a pull request read open or closed, or a read that
// cannot be made, leaves the repository to the content test. Split out of PredecessorAncestryGate+MergeTest.swift
// for the file and type length limits.

extension PredecessorAncestryGate {
    /// Runs the pull request test on each repository whose tip is not an ancestor of mainline, records the Observed
    /// Merge (evidence `pull_request`, the merge commit as its landing commit) for each where it holds, and returns
    /// the rest, in order, for the content test. With no Publication Port, it reads nothing and returns them all.
    func testPullRequests(
        of notAncestors: [RepoAncestryResult], scope: TestScope, into result: inout AncestryTestResult
    ) async throws -> [RepoAncestryResult] {
        guard let publication, !notAncestors.isEmpty else { return notAncestors }
        var remaining: [RepoAncestryResult] = []
        for notAncestor in notAncestors {
            if let merge = try await pullRequestMerge(of: notAncestor, publication: publication, scope: scope) {
                try await recordObservedMerge(merge, scope: scope)
                result.merged.append(notAncestor.repository)
            } else {
                remaining.append(notAncestor)
            }
        }
        return remaining
    }

    /// The Observed Merge the pull request test finds in one repository, or nil when it does not hold or cannot run.
    /// It cannot run without the tested commit and mainline's commit, or where `origin` names no GitHub repository:
    /// the land Act could not have opened a pull request there, so nothing is read and nothing is recorded.
    private func pullRequestMerge(
        of notAncestor: RepoAncestryResult, publication: any Publication, scope: TestScope
    ) async throws -> ObservedMerge? {
        guard
            let tipCommit = notAncestor.branchCommit,
            let mainlineCommit = notAncestor.mainlineCommit, !mainlineCommit.isEmpty,
            let repo = scope.repos.first(where: { $0.name == notAncestor.repository })
        else { return nil }
        let path = (repo.path as NSString).expandingTildeInPath
        guard
            let slug = await slugResolver.resolve(path: path),
            let selector = try pullRequestSelector(for: repo.name, scope: scope)
        else { return nil }

        let read: [ObservedPullRequest]
        do {
            read = try await publication.readPullRequests(
                PullRequestQuery(owner: slug.owner, repository: slug.repository, selector: selector)
            )
        } catch {
            try recordReadFailure(error.reason, repository: repo.name, context: scope.context)
            return nil
        }

        // Item 9 and 23: merged into any branch, but it counts only once its merge commit is in mainline, as this
        // clone has it. A merge commit the clone does not have reads as not in mainline.
        guard
            let pullRequest = Self.pullRequestUnderTest(read, pushedTip: tipCommit),
            pullRequest.state == .merged, let mergeCommit = pullRequest.mergeCommit,
            await ancestryTester.isAncestor(ancestorCommitOrRef: mergeCommit, of: mainlineCommit, in: path)
        else { return nil }
        return ObservedMerge(
            repository: repo.name, landingCommit: mergeCommit, mainlineCommit: mainlineCommit, tipCommit: tipCommit,
            evidence: .pullRequest
        )
    }

    /// Which pull request to read (OQ190 item 27): the one whose URL the land Act recorded, by its number; where no
    /// URL was recorded (Code Hosting answered that one already existed, or none was recorded at all), the pull
    /// requests whose head is the Feature Branch. Nil when neither is known.
    private func pullRequestSelector(for repository: String, scope: TestScope) throws -> PullRequestQuery.Selector? {
        let recorded = try scope.context.journal.pullRequest(featureID: scope.feature.id, repository: repository)
        if let number = PullRequestStackNotice.pullRequestNumber(fromURL: recorded?.url) {
            return .number(number)
        }
        guard let branch = scope.tips[repository]?.branch?.name, !branch.isEmpty else { return nil }
        return .headBranch(branch)
    }

    /// The pull request the test uses among those read: the one whose head is the Pushed Tip, else a merged one
    /// (OQ190 item 27). A read by number has at most one.
    static func pullRequestUnderTest(_ read: [ObservedPullRequest], pushedTip: String) -> ObservedPullRequest? {
        read.first { $0.headCommit == pushedTip } ?? read.first { $0.state == .merged }
    }

    /// Records `PullRequestReadFailed` for `repository`, at most once per repository in this pass (OQ190 item 28):
    /// several Features in U can read the same repository. Never a Failure Notice, never a halt.
    private func recordReadFailure(
        _ reason: PullRequestReadFailure.Reason, repository: String, context: ActContext
    ) throws {
        let alreadyRecorded = try context.journal.events(ofType: .pullRequestReadFailed).contains { record in
            guard record.runID == context.runID, case .pullRequestReadFailed(let recorded, _) = record.event else {
                return false
            }
            return recorded == repository
        }
        guard !alreadyRecorded else { return }
        try context.journal.append(
            .pullRequestReadFailed(repository: repository, reason: reason),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }
}
