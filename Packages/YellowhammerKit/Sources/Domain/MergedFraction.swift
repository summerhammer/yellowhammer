import Foundation

/// Represents the `k of N` merged fraction of a Feature's Feature Branches across its touched repositories.
///
/// Rendered as `<m> of <N_repos> merged` in the closed half of the roll-up lattice.
public struct MergedFraction: Equatable, Hashable, Sendable {
    /// Number of touched repositories whose mainline contains the Feature Branch (`k`).
    public let mergedCount: Int
    /// Total number of repositories touched by the Feature (`N`).
    public let totalCount: Int

    public var k: Int { mergedCount }
    public var n: Int { totalCount }

    /// Whether all touched repositories have merged the Feature Branch.
    public var isFullyMerged: Bool {
        totalCount > 0 && mergedCount == totalCount
    }

    /// Whether some but not all touched repositories have merged the Feature Branch.
    public var isPartiallyMerged: Bool {
        mergedCount > 0 && mergedCount < totalCount
    }

    /// Whether no touched repositories have merged the Feature Branch yet.
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
