/// A working repository declared in a Project's configuration.
public struct Repo: Equatable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let role: RepoRole
    public let defaultBranch: String?

    public init(
        name: String,
        path: String,
        role: RepoRole,
        defaultBranch: String? = nil
    ) {
        self.name = name
        self.path = path
        self.role = role
        self.defaultBranch = defaultBranch
    }
}

/// A named path to an existing specification checkout that a Project reads and never writes.
public struct SpecSource: Equatable, Hashable, Sendable {
    public let path: String
    public let defaultBranch: String?

    public init(
        path: String,
        defaultBranch: String? = nil
    ) {
        self.path = path
        self.defaultBranch = defaultBranch
    }
}

/// The set of repositories configured for a Project: working repositories and an optional Spec Source.
public struct ProjectRepositories: Equatable, Sendable {
    public let workingRepos: [Repo]
    public let specSource: SpecSource?

    public init(
        workingRepos: [Repo] = [],
        specSource: SpecSource? = nil
    ) {
        self.workingRepos = workingRepos
        self.specSource = specSource
    }
}

/// The resolved mainline ref and commit for a repository.
public struct ResolvedMainline: Equatable, Hashable, Sendable {
    /// The repository name, or path/identifier if unnamed.
    public let repository: String
    /// The default branch name, e.g. "main" or "master".
    public let defaultBranch: String
    /// The ref that mainline resolves to, e.g. "refs/remotes/origin/main", "refs/heads/main", or "HEAD".
    public let ref: String
    /// The 40-character hex commit SHA.
    public let commit: String

    public var commitSHA: String { commit }
    public var refName: String { ref }
    public var repositoryName: String { repository }

    public init(
        repository: String,
        defaultBranch: String,
        ref: String,
        commit: String
    ) {
        self.repository = repository
        self.defaultBranch = defaultBranch
        self.ref = ref
        self.commit = commit
    }
}

/// The set of resolved mainlines for a Project's repositories.
public struct ResolvedMainlines: Equatable, Sendable {
    public let workingRepos: [String: ResolvedMainline]
    public let specSource: ResolvedMainline?

    public init(
        workingRepos: [String: ResolvedMainline] = [:],
        specSource: ResolvedMainline? = nil
    ) {
        self.workingRepos = workingRepos
        self.specSource = specSource
    }

    public subscript(repoName: String) -> ResolvedMainline? {
        workingRepos[repoName]
    }

    public subscript(repo: Repo) -> ResolvedMainline? {
        workingRepos[repo.name]
    }
}
