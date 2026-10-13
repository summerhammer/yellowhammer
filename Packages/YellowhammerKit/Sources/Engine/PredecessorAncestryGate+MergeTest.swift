import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's merge test (spec: feature-authoring/select-the-next-feature, #merge-test,
// #net-zero-branch, #tested-tip): per repository in N with no Observed Merge, ancestry first and — only
// where that fails — the content test, both against the commit the land Act recorded. Local git reads only;
// GitHub is never asked. Split out of PredecessorAncestryGate.swift for the file and type length limits.

extension PredecessorAncestryGate {
    /// One pass's repositories, split by what this pass found: freshly merged (an Observed Merge was just
    /// recorded), unmerged (a known commit, neither an ancestor nor shown by content) and indeterminate
    /// (no commit could be resolved for the tip at all). A named type rather than a wide tuple.
    struct AncestryTestResult {
        var merged: [String] = []
        var unmerged: [String] = []
        var indeterminate: [String] = []
    }

    /// What one pass's merge tests share: the Feature, the Project's `Repo`s under test, the tip tested per
    /// repository, the branch each repository's landed pin was written under, and the Act's context.
    struct TestScope {
        let feature: FeatureRecord
        let repos: [Repo]
        let tips: [String: TestedTip]
        let pinBranches: [String: FeatureBranch]
        let context: ActContext
    }

    /// Tests the repositories with no Observed Merge yet: ancestry first, then the content test for each
    /// repository where ancestry failed. An Observed Merge is recorded for each that passed (with the
    /// evidence that found it) and its landed pin deleted; a Mainline Conflict is reported for each
    /// unmerged repository whose merge was conflicting. Empty input skips git entirely.
    func testUntestedRepositories(
        _ toTest: [String], feature: FeatureRecord, context: ActContext
    ) async throws -> AncestryTestResult {
        guard !toTest.isEmpty else { return AncestryTestResult() }
        let tips = try testedTips(for: toTest, feature: feature, journal: context.journal)
        let repos = try Self.resolveRepos(featureIssueID: feature.issueID, names: toTest, in: context.repositories)
        // The land Act pinned under the resolved branch, Worktree-name fallback included; only the pin reads it.
        let pinBranches = try context.journal.resolvedFeatureBranches(feature: feature, repositories: toTest)
        let scope = TestScope(feature: feature, repos: repos, tips: tips, pinBranches: pinBranches, context: context)
        let ancestryReport = await ancestryTester.evaluateAncestry(
            tips: tips, repos: repos, mainlines: context.mainlines
        )

        var result = AncestryTestResult()
        var notAncestors: [RepoAncestryResult] = []
        for repoResult in ancestryReport.results {
            if repoResult.isAncestor, let mainlineCommit = repoResult.mainlineCommit {
                try await recordObservedMerge(
                    ObservedMerge(
                        repository: repoResult.repository, mainlineCommit: mainlineCommit,
                        tipCommit: repoResult.branchCommit, evidence: .ancestry
                    ),
                    scope: scope
                )
                result.merged.append(repoResult.repository)
            } else if repoResult.branchCommit == nil {
                result.indeterminate.append(repoResult.repository)
            } else {
                notAncestors.append(repoResult)
            }
        }

        try await testContent(of: notAncestors, scope: scope, into: &result)
        return result
    }

    /// The tip to test per repository: the commit the land Act recorded, else the recorded Feature Branch
    /// (#tested-tip). A repository with no recorded Feature Branch is a Journal fault whether or not a commit
    /// was recorded, so it throws before any git runs. The Feature's Worktree name is deliberately not read
    /// here, or it would stand in for a record that is missing.
    private func testedTips(
        for repositories: [String], feature: FeatureRecord, journal: JournalStore
    ) throws -> [String: TestedTip] {
        let recordedBranches = try journal.featureBranches(featureID: feature.id)
        let landedCommits = try journal.landedCommits(featureID: feature.id)
        var tips: [String: TestedTip] = [:]
        for repository in repositories {
            guard recordedBranches[repository] != nil else {
                throw PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: feature.issueID)
            }
            tips[repository] = TestedTip(
                branch: recordedBranches[repository], recordedCommit: landedCommits[repository]
            )
        }
        return tips
    }

    /// The content test for the repositories whose tip is not an ancestor of mainline. One `git merge-tree`
    /// read per repository yields both the content verdict and the Mainline Conflict re-test, so it is never
    /// run twice. The very commit ancestry resolved is the one tested.
    private func testContent(
        of notAncestors: [RepoAncestryResult], scope: TestScope, into result: inout AncestryTestResult
    ) async throws {
        guard !notAncestors.isEmpty else { return }
        let context = scope.context
        var contentTips: [String: TestedTip] = [:]
        for notAncestor in notAncestors {
            contentTips[notAncestor.repository] = TestedTip(
                branch: scope.tips[notAncestor.repository]?.branch, recordedCommit: notAncestor.branchCommit
            )
        }
        let mergeReport = await mergeTester.evaluateMerge(
            tips: contentTips, repos: scope.repos.filter { contentTips[$0.name] != nil },
            mainlines: context.mainlines
        )

        for mergeResult in mergeReport.results {
            if mergeResult.isContentMerged, let mainlineCommit = mergeResult.mainlineCommit {
                try await recordObservedMerge(
                    ObservedMerge(
                        repository: mergeResult.repository, mainlineCommit: mainlineCommit,
                        tipCommit: mergeResult.branchCommit, evidence: .content
                    ),
                    scope: scope
                )
                result.merged.append(mergeResult.repository)
                continue
            }
            result.unmerged.append(mergeResult.repository)
            if mergeResult.isMainlineConflict {
                try context.journal.append(
                    .mainlineConflictDetected(
                        featureIssueID: scope.feature.issueID,
                        repository: mergeResult.repository,
                        paths: mergeResult.conflictingPaths
                    ),
                    act: context.act, runID: context.runID, nightID: context.night.id
                )
            }
        }
    }

    /// One repository's Observed Merge, as found by this pass.
    struct ObservedMerge {
        let repository: String
        let mainlineCommit: String
        let tipCommit: String?
        let evidence: ObservedMergeEvidence
    }

    /// Records the Observed Merge (first observation wins), then deletes the repository's
    /// `refs/yellowhammer/landed/<branch>` pin. A pin that cannot be deleted is reported by a Journal-only
    /// ``JournalEvent/landedPinFailed(featureIssueID:repository:branch:commit:operation:reason:)`` and never
    /// changes the gate's outcome. An Observed Merge recorded by an earlier pass already had its pin deleted.
    private func recordObservedMerge(
        _ merge: ObservedMerge, scope: TestScope
    ) async throws {
        let context = scope.context
        let feature = scope.feature
        let recorded = try context.journal.recordLanding(
            featureID: feature.id, repository: merge.repository, mainlineCommit: merge.mainlineCommit,
            evidence: merge.evidence
        )
        guard
            recorded,
            let branch = scope.pinBranches[merge.repository],
            let repo = scope.repos.first(where: { $0.name == merge.repository })
        else {
            return
        }
        let path = (repo.path as NSString).expandingTildeInPath
        guard case .failed(let reason) = await landedTipPin.unpin(branch: branch, repositoryPath: path) else {
            return
        }
        _ = try? context.journal.append(
            .landedPinFailed(
                featureIssueID: feature.issueID, repository: merge.repository, branch: branch.name,
                commit: merge.tipCommit ?? "", operation: .unpin, reason: reason
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }

    /// Resolves the Project's configured `Repo`s for every repository name given. Throws when this
    /// Project has no repositories at all, or when one of them is not among its own — the gate never
    /// guesses, and never reads a repo outside this Project's scope.
    static func resolveRepos(
        featureIssueID: String, names: [String], in repositories: ProjectRepositories?
    ) throws -> [Repo] {
        guard let repositories else {
            throw PredecessorAncestryGateError.noRepositoriesConfigured(featureIssueID: featureIssueID)
        }
        return try names.map { name in
            guard let repo = repositories.workingRepo(named: name) else {
                throw PredecessorAncestryGateError.predecessorRepositoryNotConfigured(
                    featureIssueID: featureIssueID, repository: name
                )
            }
            return repo
        }
    }
}
