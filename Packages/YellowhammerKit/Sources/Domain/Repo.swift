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

/// The resolved specification source for a Project across both kinds:
/// a dedicated Spec Source or a working repository with `role == .spec`.
public enum ProjectSpecificationSource: Equatable, Hashable, Sendable {
    case specSource(SpecSource)
    case workingRepo(Repo)

    /// The name identifying this specification repository.
    public var repositoryName: String {
        switch self {
        case .specSource:
            return "spec_source"
        case .workingRepo(let repo):
            return repo.name
        }
    }

    /// The filesystem path to this specification repository.
    public var path: String {
        switch self {
        case .specSource(let source):
            return source.path
        case .workingRepo(let repo):
            return repo.path
        }
    }

    /// The optional default branch override for this specification repository.
    public var defaultBranch: String? {
        switch self {
        case .specSource(let source):
            return source.defaultBranch
        case .workingRepo(let repo):
            return repo.defaultBranch
        }
    }
}

/// The outcome of looking up the single specification source for a Project.
public enum SpecificationSourceLookup: Equatable, Hashable, Sendable {
    case resolved(ProjectSpecificationSource)
    case none
    case multiple([String])
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

    /// Evaluates the specification sources declared for the Project.
    /// Exactly one source across both kinds (a working Repo with `role == .spec` or a `specSource`) must be present.
    public var specificationSourceLookup: SpecificationSourceLookup {
        var sources: [ProjectSpecificationSource] = []
        if let specSource {
            sources.append(.specSource(specSource))
        }
        for repo in workingRepos where repo.role == .spec {
            sources.append(.workingRepo(repo))
        }
        if sources.isEmpty {
            return .none
        } else if sources.count == 1 {
            return .resolved(sources[0])
        } else {
            return .multiple(sources.map(\.repositoryName))
        }
    }

    /// The single resolved specification source, or nil if none or multiple exist.
    public var specificationSource: ProjectSpecificationSource? {
        guard case .resolved(let source) = specificationSourceLookup else {
            return nil
        }
        return source
    }

    /// Returns whether a repository with the given name is configured in this Project,
    /// matching either a working repository or the spec source.
    public func containsRepository(named name: String) -> Bool {
        if workingRepos.contains(where: { $0.name == name }) {
            return true
        }
        let isSpecName = name == "spec_source" || name == "spec"
        if isSpecName && specSource != nil {
            return true
        }
        return false
    }

    /// Returns the working repository with the given name, if configured.
    public func workingRepo(named name: String) -> Repo? {
        workingRepos.first(where: { $0.name == name })
    }

    /// Resolves the filesystem path for a named repository within the Project's scope.
    public func repositoryPath(named name: String) -> String? {
        if let repo = workingRepo(named: name) {
            return repo.path
        }
        if let specSource, name == "spec_source" || name == "spec" {
            return specSource.path
        }
        if case .resolved(let spec) = specificationSourceLookup, spec.repositoryName == name {
            return spec.path
        }
        return nil
    }

    /// All repository names configured in this Project.
    public var allRepositoryNames: [String] {
        var names = workingRepos.map(\.name)
        if specSource != nil {
            names.append("spec_source")
        }
        return names
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
