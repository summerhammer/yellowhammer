import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's merge test (spec: feature-authoring/select-the-next-feature, #merge-test,
// #net-zero-branch, #tested-tip): per repository in N with no Observed Merge, ancestry first and — only
// where that fails — the content test, both against the commit the land Act recorded. Each Observed Merge records
// its landing commit, where the change entered mainline (OQ190 item 26). Local git reads only; GitHub is never
// asked. Split out of PredecessorAncestryGate.swift for the file and type length limits.

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
    /// repository, the branch each repository's landed pin was written under, the Act's context and the running
    /// git's version, read once per gate pass.
    struct TestScope {
        let feature: FeatureRecord
        let repos: [Repo]
        let tips: [String: TestedTip]
        let pinBranches: [String: FeatureBranch]
        let context: ActContext
        let gitVersion: PassGitVersion
    }

    /// Tests the repositories with no Observed Merge yet: ancestry first, then the content test for each
    /// repository where ancestry failed. An Observed Merge is recorded for each that passed (with the
    /// evidence that found it and its landing commit) and its landed pin deleted; a Mainline Conflict is
    /// reported for each unmerged repository whose merge into mainline's head was conflicting. A tip that is an
    /// ancestor but whose landing commit git could not read goes on to the content test, as any test that cannot
    /// run does (OQ190 item 22). Empty input skips git entirely.
    func testUntestedRepositories(
        _ toTest: [String], feature: FeatureRecord, context: ActContext, gitVersion: PassGitVersion
    ) async throws -> AncestryTestResult {
        guard !toTest.isEmpty else { return AncestryTestResult() }
        let tips = try testedTips(for: toTest, feature: feature, journal: context.journal)
        let repos = try Self.resolveRepos(featureIssueID: feature.issueID, names: toTest, in: context.repositories)
        // The land Act pinned under the resolved branch, Worktree-name fallback included; only the pin reads it.
        let pinBranches = try context.journal.resolvedFeatureBranches(feature: feature, repositories: toTest)
        let scope = TestScope(
            feature: feature, repos: repos, tips: tips, pinBranches: pinBranches, context: context,
            gitVersion: gitVersion
        )
        let ancestryReport = await ancestryTester.evaluateAncestry(
            tips: tips, repos: repos, mainlines: context.mainlines
        )

        var result = AncestryTestResult()
        var notAncestors: [RepoAncestryResult] = []
        for repoResult in ancestryReport.results {
            if repoResult.isAncestor, let mainlineCommit = repoResult.mainlineCommit,
               let landingCommit = repoResult.landingCommit {
                try await recordObservedMerge(
                    ObservedMerge(
                        repository: repoResult.repository, landingCommit: landingCommit,
                        mainlineCommit: mainlineCommit, tipCommit: repoResult.branchCommit, evidence: .ancestry
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

    /// The tip to test per repository: the Pushed Tip, else the recorded Feature Branch
    /// (#tested-tip). A repository with no recorded Feature Branch is a Journal fault whether or not a commit
    /// was recorded, so it throws before any git runs. The Feature's Worktree name is deliberately not read
    /// here, or it would stand in for a record that is missing.
    private func testedTips(
        for repositories: [String], feature: FeatureRecord, journal: JournalStore
    ) throws -> [String: TestedTip] {
        let recordedBranches = try journal.featureBranches(featureID: feature.id)
        let pushedTips = try journal.pushedTips(featureID: feature.id)
        var tips: [String: TestedTip] = [:]
        for repository in repositories {
            guard recordedBranches[repository] != nil else {
                throw PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: feature.issueID)
            }
            tips[repository] = TestedTip(
                branch: recordedBranches[repository], recordedCommit: pushedTips[repository]
            )
        }
        return tips
    }

    /// The content test for the repositories whose tip is not an ancestor of mainline: a search of mainline's
    /// first-parent history for the commit where the change entered it (OQ190 item 24), anchored for a stacked
    /// Feature on the lower Feature's landing commit and not run before it (OQ190 item 25; see
    /// ``contentTestPlan(for:scope:)``). The Mainline Conflict re-test stays a read of mainline's head, which the
    /// same pass returns. The very commit ancestry resolved is the one tested.
    private func testContent(
        of notAncestors: [RepoAncestryResult], scope: TestScope, into result: inout AncestryTestResult
    ) async throws {
        guard !notAncestors.isEmpty else { return }
        let context = scope.context
        var mergeResults: [RepoMergeResult] = []
        for repo in scope.repos {
            guard let notAncestor = notAncestors.first(where: { $0.repository == repo.name }) else { continue }
            let tip = TestedTip(branch: scope.tips[repo.name]?.branch, recordedCommit: notAncestor.branchCommit)
            mergeResults.append(
                await contentResult(
                    of: tip, in: repo, plan: try await contentTestPlan(for: repo.name, scope: scope),
                    mainline: context.mainlines[repo.name]
                )
            )
        }

        for mergeResult in mergeResults {
            if mergeResult.isContentMerged, let mainlineCommit = mergeResult.mainlineCommit,
               let landingCommit = mergeResult.landingCommit {
                try await recordObservedMerge(
                    ObservedMerge(
                        repository: mergeResult.repository, landingCommit: landingCommit,
                        mainlineCommit: mainlineCommit, tipCommit: mergeResult.branchCommit, evidence: .content
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
        /// Where the change entered mainline.
        let landingCommit: String
        /// Mainline's commit at this observation.
        let mainlineCommit: String
        let tipCommit: String?
        let evidence: ObservedMergeEvidence
    }

    /// Records the Observed Merge (first observation wins), then deletes the repository's
    /// `refs/yellowhammer/landed/<branch>` pin — unless an unarchived Cycle's recorded base names it (spec:
    /// `#tested-tip`, agent rulings item 1): that Cycle's lanes not yet allocated are cut from it, so the pin is
    /// kept and deleted when that Cycle archives (``LandedPinRelease/releaseBasePins(of:repositories:journal:)``).
    /// A pin that cannot be deleted is reported by a Journal-only
    /// ``JournalEvent/landedPinFailed(featureIssueID:repository:branch:commit:operation:reason:)`` and never
    /// changes the gate's outcome. An Observed Merge recorded by an earlier pass already had its pin handled.
    private func recordObservedMerge(
        _ merge: ObservedMerge, scope: TestScope
    ) async throws {
        let context = scope.context
        let feature = scope.feature
        let recorded = try context.journal.recordLanding(
            featureID: feature.id, repository: merge.repository, landingCommit: merge.landingCommit,
            mainlineCommit: merge.mainlineCommit, evidence: merge.evidence
        )
        guard
            recorded,
            let branch = scope.pinBranches[merge.repository],
            let repo = scope.repos.first(where: { $0.name == merge.repository })
        else {
            return
        }
        guard !(try context.journal.isBaseOfOpenCycle(
            repository: merge.repository, baseRef: LandedTipPin.ref(for: branch)
        )) else {
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
