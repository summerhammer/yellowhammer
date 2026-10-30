import Domain
import Foundation
import Journal
import Repositories

// The predecessor gate's content test for a stacked Feature (spec: feature-authoring/select-the-next-feature,
// #stacked-content-test, #net-zero-branch; OQ190 item 25): where a Feature's recorded base in a repository is the
// Pushed Tip of a Feature below it, the content test there runs only once that Feature has its Observed Merge, from
// its landing commit, with the recorded base as the base of each three-way merge. Split out of
// PredecessorAncestryGate+MergeTest.swift for the file and type length limits.

/// The running git's version, read at most once per gate pass, and only when a stacked Feature's content test
/// needs it.
actor PassGitVersion {
    private let reader: GitVersionReader
    private var cached: GitVersion??

    init(reader: GitVersionReader) {
        self.reader = reader
    }

    func version() async -> GitVersion? {
        if let cached { return cached }
        let version = await reader.read()
        cached = .some(version)
        return version
    }
}

extension PredecessorAncestryGate {
    /// How the content test runs in one repository whose tip is not an ancestor of mainline.
    enum ContentTestPlan: Equatable {
        /// The Feature's base there is mainline: the search starts after the fork point (OQ190 item 24).
        case fromForkPoint
        /// The Feature is stacked there on a Feature below it that has its Observed Merge: the search starts at
        /// that Feature's landing commit, with the recorded base as the merge base (OQ190 item 25).
        case stacked(StackedContentAnchor)
        /// The Feature is stacked there, and the content test cannot run this pass: the Feature below has no
        /// Observed Merge there yet, or the running git is older than 2.40 and cannot take the recorded base as
        /// the merge base. Never the unanchored search instead, which reads mainline from before the lower Feature
        /// landed as a stacked Feature that undid part of it. Only the Mainline Conflict re-test runs.
        case notRun
    }

    /// The plan for `repository`. A Feature is stacked there when its recorded base names a Feature below it
    /// (`feature_base.stacked_on_feature_id`; its `base_commit` is that Feature's Pushed Tip). The lower Feature's
    /// landing commit is read now, not at the start of the pass: U is tested oldest first, so an Observed Merge this
    /// pass just recorded for the Feature below is the anchor of the Feature above it in the same pass.
    func contentTestPlan(for repository: String, scope: TestScope) async throws -> ContentTestPlan {
        let journal = scope.context.journal
        guard
            let base = try journal.featureBases(featureID: scope.feature.id).first(where: {
                $0.repository == repository
            }),
            let lowerFeatureID = base.stackedOnFeatureID
        else { return .fromForkPoint }
        guard let landingCommit = try journal.landingCommits(featureID: lowerFeatureID)[repository],
              await scope.gitVersion.version()?.mergeTreeTakesMergeBase == true
        else { return .notRun }
        return .stacked(StackedContentAnchor(recordedBase: base.baseCommit, lowerLandingCommit: landingCommit))
    }

    /// One repository's content result under `plan`. `.notRun` reads only the merge into mainline's head, which
    /// carries no landing commit, so the repository stays unmerged and a Mainline Conflict is still reported.
    func contentResult(
        of tip: TestedTip, in repo: Repo, plan: ContentTestPlan, mainline: ResolvedMainline?
    ) async -> RepoMergeResult {
        let branch = tip.branch?.name ?? ""
        switch plan {
        case .fromForkPoint:
            return await mergeTester.testContent(
                branch: branch, recordedCommit: tip.recordedCommit, in: repo, mainline: mainline
            )
        case .stacked(let anchor):
            return await mergeTester.testStackedContent(
                branch: branch, recordedCommit: tip.recordedCommit, in: repo, anchor: anchor, mainline: mainline
            )
        case .notRun:
            return await mergeTester.testMerge(
                branch: branch, recordedCommit: tip.recordedCommit, in: repo, mainline: mainline
            )
        }
    }
}
