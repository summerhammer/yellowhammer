import Foundation

// Where a tip that is an ancestor of mainline entered it (feature-authoring/select-the-next-feature, the Observed
// Merge record; OQ190 item 26). Split out of AncestryTester.swift for the file and type length limits.

extension AncestryTester {
    /// The oldest commit on `mainline`'s first-parent chain that has `tip` as an ancestor, or nil when `tip` is not
    /// an ancestor of `mainline` or git cannot read the chain.
    ///
    /// `git rev-list --first-parent --reverse <tip>..<mainline>` lists the chain's commits that `tip` does not
    /// reach, oldest first. Along a first-parent chain, containing `tip` is monotone (every later commit contains
    /// what an earlier one does), so the oldest listed commit that contains it is found by bisection with
    /// `git merge-base --is-ancestor`. When that commit's first parent is `tip` itself, `tip` is on the chain (a
    /// fast-forward) and is the answer; otherwise it is the merge that brought `tip` in. Only reads whose meaning
    /// predates git 2.38, the required minimum.
    public func landingCommit(of tip: String, mainline: String, in repositoryPath: String) async -> String? {
        if tip == mainline { return tip }
        let listed = await git.run([
            "-C", repositoryPath, "rev-list", "--first-parent", "--reverse", "\(tip)..\(mainline)"
        ])
        guard listed.isSuccess else { return nil }
        let chain = listed.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard let newest = chain.last,
              await isAncestor(ancestorCommitOrRef: tip, of: newest, in: repositoryPath)
        else { return nil }

        var low = 0
        var high = chain.count - 1
        while low < high {
            let middle = (low + high) / 2
            if await isAncestor(ancestorCommitOrRef: tip, of: chain[middle], in: repositoryPath) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        let oldest = chain[low]
        let firstParent = await git.run(["-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(oldest)^1"])
        guard firstParent.isSuccess else { return nil }
        return firstParent.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == tip ? tip : oldest
    }
}
