import Foundation

/// The branch Orca ADE reports at allocation for one (Feature, repository).
///
/// It is the Worktree name, optionally preceded by `<prefix>/` from Orca ADE's branch-name prefix
/// setting (the prefix may itself contain `/`). Recorded in the Journal per (Feature, repository),
/// fixed once recorded, and never renamed by Yellowhammer.
public struct FeatureBranch: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public var name: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(name: String) {
        self.rawValue = name
    }
}

extension FeatureBranch: CustomStringConvertible {
    public var description: String { rawValue }
}

extension FeatureBranch: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}
