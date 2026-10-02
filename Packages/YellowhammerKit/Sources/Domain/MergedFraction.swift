import Foundation

/// Represents the `k of N` merged fraction of a Feature's Feature Branches across the repositories that pushed a Feature Branch (N), not `touched_repos`.
///
/// Rendered as `<m> of <N_repos> merged` in the closed half of the roll-up lattice.
public struct MergedFraction: Equatable, Hashable, Sendable {
    /// Number of the repositories that pushed a Feature Branch whose mainline contains it (`k`).
    public let mergedCount: Int
    /// Total number of repositories that pushed a Feature Branch (`N`); a repository with a No-Pushed-Branch Outcome is not counted.
    public let totalCount: Int

    // Spec-verbatim compatibility aliases; callers may still use k of N notation.
    // swiftlint:disable:next identifier_name
    public var k: Int { mergedCount }
    // swiftlint:disable:next identifier_name
    public var n: Int { totalCount }

    /// Whether all the pushed repositories have merged the Feature Branch.
    public var isFullyMerged: Bool {
        totalCount > 0 && mergedCount == totalCount
    }

    /// Whether some but not all the pushed repositories have merged the Feature Branch.
    public var isPartiallyMerged: Bool {
        mergedCount > 0 && mergedCount < totalCount
    }

    /// Whether none of the pushed repositories has merged the Feature Branch yet.
    public var isUnmerged: Bool {
        mergedCount == 0
    }

    public var formatted: String {
        "\(mergedCount) of \(totalCount) merged"
    }

    public init(mergedCount: Int, totalCount: Int) {
        self.mergedCount = max(0, mergedCount)
        self.totalCount = max(0, totalCount)
    }
}

extension MergedFraction: CustomStringConvertible {
    public var description: String {
        formatted
    }
}
