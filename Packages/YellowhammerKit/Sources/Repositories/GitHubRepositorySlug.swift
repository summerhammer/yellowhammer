import Foundation

/// A repository's owner/name slug, parsed from a `git remote get-url origin` value. Opening a pull
/// request (roadmap P10.4) needs this to address GitHub's REST API — the local checkout is read-only
/// evidence for it; nothing here writes.
public struct GitHubRepositorySlug: Equatable, Sendable {
    public let owner: String
    public let repository: String

    public init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
    }

    /// Parses `https://github.com/o/r(.git)`, `git@github.com:o/r(.git)`, and
    /// `ssh://git@github.com/o/r(.git)`. Nil for anything else — a different host, a malformed URL, or
    /// a value with no owner/repository pair.
    public static func parse(_ remoteURL: String) -> GitHubRepositorySlug? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path: String
        if trimmed.hasPrefix("git@github.com:") {
            path = String(trimmed.dropFirst("git@github.com:".count))
        } else if let url = URL(string: trimmed), let host = url.host, host.lowercased() == "github.com" {
            path = url.path
        } else {
            return nil
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2 else { return nil }
        var repository = components.removeLast()
        if repository.hasSuffix(".git") {
            repository = String(repository.dropLast(4))
        }
        let owner = components.last ?? ""
        guard !owner.isEmpty, !repository.isEmpty else { return nil }
        return GitHubRepositorySlug(owner: owner, repository: repository)
    }
}

/// Resolves a repository's GitHub slug from its local `origin` remote.
public struct GitHubRepositorySlugResolver: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Reads `git -C <path> remote get-url origin` and parses it. Nil when the remote could not be
    /// read, or did not parse as a GitHub slug.
    public func resolve(path: String) async -> GitHubRepositorySlug? {
        let result = await git.run(["-C", path, "remote", "get-url", "origin"])
        guard result.isSuccess else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        return GitHubRepositorySlug.parse(url)
    }
}
