import Foundation

/// A parsed `git --version` version number, and whether it meets a minimum.
public struct GitVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public func meets(minimumMajor: Int, minimumMinor: Int) -> Bool {
        (major, minor) >= (minimumMajor, minimumMinor)
    }

    /// Whether `git merge-tree --write-tree` takes `--merge-base=<commit>`, added in git 2.40. A stacked Feature's
    /// content test needs it: its three-way merges use the recorded base, not the fork point
    /// (feature-authoring/select-the-next-feature, #stacked-content-test).
    public var mergeTreeTakesMergeBase: Bool {
        meets(minimumMajor: 2, minimumMinor: 40)
    }

    /// Parses `"git version 2.39.5 (Apple Git-154)"` into `(2, 39, 5)`. Requires the literal
    /// `"git version "` prefix followed by at least a `major.minor` dotted number; anything else
    /// (including a version with fewer than two components) fails to parse.
    public static func parse(_ output: String) -> GitVersion? {
        let prefix = "git version "
        guard let range = output.range(of: prefix) else { return nil }
        let rest = output[range.upperBound...]
        let token = rest.prefix { $0.isNumber || $0 == "." }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        let patch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
        return GitVersion(major: major, minor: minor, patch: patch)
    }
}

extension GitVersion: CustomStringConvertible {
    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Where a reader of the running git's version gets it: `git --version`, or a fixed value a test injects in place
/// of an older git.
public struct GitVersionReader: Sendable {
    private enum Source: Sendable {
        case git(GitRunner)
        case fixed(GitVersion?)
    }

    private let source: Source

    /// Reads `git --version` through `git`.
    public init(git: GitRunner = GitRunner()) {
        source = .git(git)
    }

    /// Answers `version` without running git; nil reads as a version git did not report.
    public init(fixed version: GitVersion?) {
        source = .fixed(version)
    }

    /// The running git's version; nil when `git --version` fails or prints something unparseable.
    public func read() async -> GitVersion? {
        switch source {
        case .fixed(let version):
            return version
        case .git(let git):
            let result = await git.run(["--version"])
            return result.isSuccess ? GitVersion.parse(result.stdout) : nil
        }
    }
}
