import Domain
import Foundation

// The merge test's content test (feature-authoring/select-the-next-feature, #merge-test, #net-zero-branch): whether
// mainline's history contains the branch's change, and the commit where it entered mainline. Split out of
// MergeTester.swift for the file and type length limits.

extension MergeTester {
    /// Runs the content test across `repos`, each against its own ``TestedTip``: the recorded commit alone when
    /// one was recorded, else the Feature Branch (#tested-tip). A repository absent from `tips`, or whose tip
    /// resolves to no commit (including a recorded commit the repository lost), is untestable.
    public func evaluateContent(
        tips: [String: TestedTip],
        repos: [Repo],
        mainlines: ResolvedMainlines? = nil
    ) async -> FeatureMergeReport {
        var results: [RepoMergeResult] = []
        for repo in repos {
            let tip = tips[repo.name] ?? TestedTip(branch: nil)
            results.append(
                await testContent(
                    branch: tip.branchName, recordedCommit: tip.recordedCommit, in: repo,
                    mainline: mainlines?[repo.name]
                )
            )
        }
        return FeatureMergeReport(branches: tips.compactMapValues(\.branch), results: results)
    }

    /// The content test of one repository (OQ190 item 24). It searches mainline's first-parent chain after the
    /// fork point (`git merge-base <mainline> <tip>`), oldest first, for the first commit C where
    /// `git merge-tree --write-tree C <tip>` exits clean and writes C's own tree: merging the tip into C would
    /// change nothing, so C is the ``RepoMergeResult/landingCommit``. Searching the history rather than reading
    /// mainline's head means a later edit to the same lines does not hide a squash or rebase merge. The search
    /// runs only when the tip's tree differs from the fork point's (#net-zero-branch).
    ///
    /// The verdict is always that of a merge into mainline's head, a separate read, so a conflict at an earlier
    /// commit of the chain is never a Mainline Conflict; when the search reaches the head, that read is reused.
    /// `mainline` may be a tag's commit in place of mainline (the release gate's test (B)).
    public func testContent(
        branch: String,
        recordedCommit: String?,
        in repo: Repo,
        mainline: ResolvedMainline? = nil
    ) async -> RepoMergeResult {
        let read: ResolvedMergeRead
        switch await resolveMergeRead(branch: branch, recordedCommit: recordedCommit, in: repo, mainline: mainline) {
        case .resolved(let resolved): read = resolved
        case .untestable(let result): return result
        }

        let fork = await forkPoint(of: read.branchCommit, mainline: read.mainlineCommit, in: read.path)
        var tipHasNetChange: Bool?
        if let fork {
            tipHasNetChange = await hasNetChange(tip: read.branchCommit, base: fork, in: read.path)
        }
        var headMerge: (verdict: MergeVerdict, tree: String?)?
        var landingCommit: String?
        if let fork, tipHasNetChange == true {
            for candidate in await firstParentChain(after: fork, upTo: read.mainlineCommit, in: read.path) {
                let merge = await mergeTree(
                    mainlineCommit: candidate.commit, branchCommit: read.branchCommit, in: read.path
                )
                if candidate.commit == read.mainlineCommit { headMerge = merge }
                if case .clean = merge.verdict, merge.tree == candidate.tree {
                    landingCommit = candidate.commit
                    break
                }
            }
        }
        let head: (verdict: MergeVerdict, tree: String?)
        if let headMerge {
            head = headMerge
        } else {
            head = await mergeTree(mainlineCommit: read.mainlineCommit, branchCommit: read.branchCommit, in: read.path)
        }
        return read.result(
            verdict: head.verdict, mergedTree: head.tree, tipHasNetChange: tipHasNetChange,
            landingCommit: landingCommit
        )
    }

    /// `git merge-base <mainline> <tip>`: where the branch left mainline. Nil for unrelated histories.
    private func forkPoint(of tip: String, mainline: String, in path: String) async -> String? {
        let result = await git.run(["-C", path, "merge-base", mainline, tip])
        let commit = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isSuccess && !commit.isEmpty ? commit : nil
    }

    /// Whether `tip`'s tree differs from `base`'s. Nil when git cannot read either tree.
    private func hasNetChange(tip: String, base: String, in path: String) async -> Bool? {
        guard let baseTree = await treeOID(of: base, in: path), let tipTree = await treeOID(of: tip, in: path)
        else { return nil }
        return baseTree != tipTree
    }

    /// The tree of `commit`, nil when git cannot read it.
    private func treeOID(of commit: String, in path: String) async -> String? {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(commit)^{tree}"])
        guard result.isSuccess else { return nil }
        let tree = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return tree.isEmpty ? nil : tree
    }

    /// Mainline's first-parent chain after `fork`, oldest first, each commit with its tree, read in one
    /// `git rev-list --first-parent --reverse --format=%T <fork>..<mainline>`. Its output pairs a
    /// `commit <oid>` line with the tree line. Empty when git cannot read it.
    private func firstParentChain(
        after fork: String, upTo mainline: String, in path: String
    ) async -> [(commit: String, tree: String)] {
        let result = await git.run([
            "-C", path, "rev-list", "--first-parent", "--reverse", "--format=%T", "\(fork)..\(mainline)"
        ])
        guard result.isSuccess else { return [] }
        var chain: [(commit: String, tree: String)] = []
        var commit: String?
        for line in result.stdout.split(separator: "\n").map(String.init) {
            if line.hasPrefix("commit ") {
                commit = String(line.dropFirst("commit ".count))
            } else if let current = commit, !line.isEmpty {
                chain.append((current, line))
                commit = nil
            }
        }
        return chain
    }
}
