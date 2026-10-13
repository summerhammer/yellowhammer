import Foundation

// The content test's two reads beyond `git merge-tree` (feature-authoring/select-the-next-feature, #merge-test):
// whether the tip changes anything at all (#net-zero-branch), and which tree mainline has. Split out of
// MergeTester.swift for the file and function length limits.

extension MergeTester {
    /// The reads only a clean merge needs; both nil for any other verdict.
    func contentReads(
        verdict: MergeVerdict, tip: String, mainline: String, in path: String
    ) async -> (mainlineTree: String?, tipHasNetChange: Bool?) {
        guard case .clean = verdict else { return (nil, nil) }
        return (
            await treeOID(of: mainline, in: path),
            await hasNetChange(tip: tip, mainline: mainline, in: path)
        )
    }

    /// The tree of `commit`, nil when git cannot read it.
    private func treeOID(of commit: String, in path: String) async -> String? {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(commit)^{tree}"])
        guard result.isSuccess else { return nil }
        let tree = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return tree.isEmpty ? nil : tree
    }

    /// Whether `tip`'s tree differs from the tree of `git merge-base <mainline> <tip>`. Nil when there is no
    /// merge base (unrelated histories) or git cannot read a tree.
    private func hasNetChange(tip: String, mainline: String, in path: String) async -> Bool? {
        let base = await git.run(["-C", path, "merge-base", mainline, tip])
        let baseCommit = base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.isSuccess, !baseCommit.isEmpty,
              let baseTree = await treeOID(of: baseCommit, in: path),
              let tipTree = await treeOID(of: tip, in: path)
        else { return nil }
        return baseTree != tipTree
    }
}
