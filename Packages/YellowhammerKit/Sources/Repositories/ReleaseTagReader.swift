import Foundation

/// Reads a producer Repo's release-shaped tags (feature-authoring/select-the-next-feature, `#release-gate`).
/// Pure local git: it never fetches, and Yellowhammer never creates, pushes or moves a tag.
public struct ReleaseTagReader: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The release-shaped tags of the repository at `path`, newest version first. Release-shaped is
    /// `MAJOR.MINOR.PATCH` with an optional leading `v` and no pre-release suffix, so `v1.2.3-rc.1` is not a
    /// release. `commit` is the commit the tag names: the peeled object of an annotated tag, else the tag's own.
    public func releaseTags(in path: String) async -> [(name: String, commit: String)] {
        let result = await git.run([
            "-C", path, "for-each-ref", "--sort=-v:refname",
            "--format=%(refname:short)%09%(objectname)%09%(*objectname)", "refs/tags"
        ])
        guard result.isSuccess else { return [] }
        var tags: [(name: String, commit: String)] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, Self.isReleaseShaped(fields[0]) else { continue }
            let commit = fields[2].isEmpty ? fields[1] : fields[2]
            tags.append((name: fields[0], commit: commit))
        }
        // git's version sort places a `v`-prefixed name after a bare one; order by the numbers alone.
        return tags.sorted { Self.version($1.name).lexicographicallyPrecedes(Self.version($0.name)) }
    }

    /// Whether `commit` is an ancestor of, or the same commit as, `tagCommit` in the repository at `path`.
    public func contains(_ commit: String, tag tagCommit: String, in path: String) async -> Bool {
        // Object names only, so a value can never be read as an option.
        guard Self.isObjectName(commit), Self.isObjectName(tagCommit) else { return false }
        let result = await git.run(["-C", path, "merge-base", "--is-ancestor", commit, tagCommit])
        return result.exitCode == 0
    }

    /// `[major, minor, patch]` of a release-shaped name.
    private static func version(_ name: String) -> [Int] {
        (name.hasPrefix("v") ? String(name.dropFirst()) : name).split(separator: ".").compactMap { Int($0) }
    }

    static func isReleaseShaped(_ name: String) -> Bool {
        let version = name.hasPrefix("v") ? String(name.dropFirst()) : name
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
    }

    private static func isObjectName(_ value: String) -> Bool {
        (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
