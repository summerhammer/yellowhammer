import Foundation

/// Where each repository's fresh checkout sits under the fresh-checkout root (spec:
/// verification/verify-a-feature-clause-by-clause, `#judged-checkout`; OQ191 items 2, 7 and 8): the same relative
/// arrangement as the held Worktrees, so a Check that reads a sibling directory reads that sibling's checkout.
///
/// A held Worktree keeps its path relative to the deepest directory holding every held Worktree's parent, so
/// even a single held Worktree keeps its own directory name. A repository with no held Worktree — one no Work
/// Card names — sits at `<root>/<repository>` (Operator decision for OQ195), with a numeric suffix when that
/// path is taken by, inside or around another repository's.
enum FreshCheckoutLayout {
    /// Each repository's path relative to the root, by repository name. `heldWorktrees` holds the held
    /// Worktrees' paths by repository; `repositories` names every repository to place.
    static func relativePaths(heldWorktrees: [String: String], repositories: [String]) -> [String: String] {
        let components = heldWorktrees.mapValues {
            URL(fileURLWithPath: $0).standardizedFileURL.pathComponents.filter { $0 != "/" }
        }
        let parents = components.values.map { Array($0.dropLast()) }
        let ancestor = parents.dropFirst().reduce(parents.first ?? []) { common, next in
            Array(zip(common, next).prefix { $0 == $1 }.map(\.0))
        }

        var relative: [String: String] = [:]
        for (repository, path) in components.sorted(by: { $0.key < $1.key }) {
            relative[repository] = path.dropFirst(ancestor.count).joined(separator: "/")
        }
        for repository in repositories.sorted() where relative[repository] == nil {
            var candidate = repository
            var suffix = 2
            while relative.values.contains(where: { overlaps(candidate, $0) }) {
                candidate = "\(repository)-\(suffix)"
                suffix += 1
            }
            relative[repository] = candidate
        }
        return relative
    }

    /// Whether two relative paths are the same directory or one holds the other.
    private static func overlaps(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }
}
