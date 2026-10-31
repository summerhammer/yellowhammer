import Domain
import Foundation

/// What a stacked Feature's content test in one repository is anchored on (feature-authoring/select-the-next-feature,
/// #stacked-content-test, OQ190 item 25): the Feature's recorded base there, which is the Pushed Tip of the Feature
/// below it, and the landing commit of that lower Feature's Observed Merge.
public struct StackedContentAnchor: Equatable, Sendable {
    /// The Feature's recorded base (`feature_base.base_commit`): the base of each three-way merge and of the
    /// net-change check, in place of the fork point with mainline.
    public let recordedBase: String
    /// Where the lower Feature's change entered mainline: the search starts here.
    public let lowerLandingCommit: String

    public init(recordedBase: String, lowerLandingCommit: String) {
        self.recordedBase = recordedBase
        self.lowerLandingCommit = lowerLandingCommit
    }
}

extension MergeTester {
    /// The content test of a stacked Feature in one repository (#stacked-content-test, OQ190 item 25). It searches
    /// mainline's first-parent chain from the lower Feature's landing commit, that commit included, oldest first,
    /// for the first commit C where `git merge-tree --write-tree --merge-base=<recorded base> C <tip>` exits clean
    /// and writes C's own tree; C is the ``RepoMergeResult/landingCommit``. The landing commit is included because
    /// an upper pull request merged into the lower Feature's branch before that branch was squash-merged entered
    /// mainline in the same commit (#stacked-merge-order). The search runs only when the tip's tree differs from the
    /// recorded base's (#net-zero-branch), and only when the landing commit is an ancestor of mainline: otherwise
    /// `<landing>..<mainline>` would reach back past the lower Feature into the history the anchor excludes, and
    /// mainline from before the lower Feature landed reads as a stacked Feature that undid part of it.
    ///
    /// The caller decides that the running git takes `--merge-base` (``GitVersion/mergeTreeTakesMergeBase``). The
    /// verdict is a merge into mainline's head with no `--merge-base`, the same separate read as the plain content
    /// test, so the Mainline Conflict re-test is unchanged.
    public func testStackedContent(
        branch: String,
        recordedCommit: String?,
        in repo: Repo,
        anchor: StackedContentAnchor,
        mainline: ResolvedMainline? = nil
    ) async -> RepoMergeResult {
        let read: ResolvedMergeRead
        switch await resolveMergeRead(branch: branch, recordedCommit: recordedCommit, in: repo, mainline: mainline) {
        case .resolved(let resolved): read = resolved
        case .untestable(let result): return result
        }

        var tipHasNetChange: Bool?
        var landingCommit: String?
        if let base = await git.existingCommit(anchor.recordedBase, in: read.path) {
            tipHasNetChange = await hasNetChange(tip: read.branchCommit, base: base, in: read.path)
            if tipHasNetChange == true {
                landingCommit = await searchLandingCommit(of: read, from: anchor.lowerLandingCommit, base: base)
            }
        }
        let head = await mergeTree(mainlineCommit: read.mainlineCommit, branchCommit: read.branchCommit, in: read.path)
        return read.result(
            verdict: head.verdict, mergedTree: head.tree, tipHasNetChange: tipHasNetChange,
            landingCommit: landingCommit
        )
    }

    /// The first commit of `anchoredChain(from:upTo:tip:base:in:)` that absorbs the tip with `base` as the merge
    /// base.
    private func searchLandingCommit(of read: ResolvedMergeRead, from anchor: String, base: String) async -> String? {
        let chain = await anchoredChain(
            from: anchor, upTo: read.mainlineCommit, tip: read.branchCommit, base: base, in: read.path
        )
        for candidate in chain {
            let merge = await mergeTree(
                mainlineCommit: candidate.commit, branchCommit: read.branchCommit, mergeBase: base, in: read.path
            )
            if case .clean = merge.verdict, merge.tree == candidate.tree { return candidate.commit }
        }
        return nil
    }

    /// `anchor` and mainline's first-parent chain after it, oldest first, each commit with its tree; after `anchor`,
    /// only the commits that touch the paths `tip` changes against `base` when that finds the same commit
    /// (``landingCandidates(after:upTo:tip:base:in:)``). `--merge-base` makes `base` every merge's base.
    /// Empty when `anchor` is not a commit this repository has, or not an ancestor of `mainline`.
    private func anchoredChain(
        from anchor: String, upTo mainline: String, tip: String, base: String, in path: String
    ) async -> [(commit: String, tree: String)] {
        guard
            let anchor = await git.existingCommit(anchor, in: path),
            await git.run(["-C", path, "merge-base", "--is-ancestor", anchor, mainline]).isSuccess,
            let anchorTree = await treeOID(of: anchor, in: path)
        else { return [] }
        return [(anchor, anchorTree)]
            + (await landingCandidates(after: anchor, upTo: mainline, tip: tip, base: base, in: path))
    }
}
