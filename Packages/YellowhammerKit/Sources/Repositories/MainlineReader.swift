import Domain
import Foundation

/// Reads files at mainline commits and transcribes contracts from Project repositories.
///
/// Mainline reads touch no working tree, write no commit, and move no ref.
public struct MainlineReader: Sendable {
    public let git: GitRunner
    public let refresher: MainlineRefresher

    public init(
        git: GitRunner = GitRunner(),
        refresher: MainlineRefresher? = nil
    ) {
        self.git = git
        self.refresher = refresher ?? MainlineRefresher(git: git)
    }

    /// Validates that a Project has exactly one specification source across both kinds.
    public func validateSpecificationSource(
        in projectRepositories: ProjectRepositories
    ) throws -> ProjectSpecificationSource {
        switch projectRepositories.specificationSourceLookup {
        case .resolved(let source):
            return source
        case .none:
            throw MainlineReadError.noSpecificationSource
        case .multiple(let sources):
            throw MainlineReadError.multipleSpecificationSources(sources)
        }
    }

    /// Sanitizes and validates that a repository-relative path does not escape the repository root.
    public func sanitizeRepoRelativePath(_ path: String, repositoryPath: String) throws -> String {
        let rawPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            throw MainlineReadError.pathEscapesRepository(path)
        }

        var relativePath = rawPath
        let expandedRepoPath = (repositoryPath as NSString).expandingTildeInPath
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        if expandedPath == expandedRepoPath {
            throw MainlineReadError.pathEscapesRepository(path)
        } else if expandedPath.hasPrefix(expandedRepoPath + "/") {
            relativePath = String(expandedPath.dropFirst(expandedRepoPath.count + 1))
        } else if expandedPath.hasPrefix("/") {
            throw MainlineReadError.pathEscapesRepository(path)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        var depth = 0
        var normalized: [String] = []
        for component in components {
            if component == "." {
                continue
            } else if component == ".." {
                depth -= 1
                if depth < 0 {
                    throw MainlineReadError.pathEscapesRepository(path)
                }
                if !normalized.isEmpty {
                    normalized.removeLast()
                }
            } else {
                depth += 1
                normalized.append(String(component))
            }
        }
        guard depth >= 0, !normalized.isEmpty else {
            throw MainlineReadError.pathEscapesRepository(path)
        }
        return normalized.joined(separator: "/")
    }

    /// Reads file content at a mainline commit in a working repository.
    public func readFile(
        path: String,
        in repo: Repo,
        commit: String? = nil,
        mainline: ResolvedMainline? = nil
    ) async throws -> MainlineFileRead {
        let expandedPath = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw MainlineReadError.missingRepository(repository: repo.name, path: repo.path)
        }
        let sanitized = try sanitizeRepoRelativePath(path, repositoryPath: expandedPath)
        let resolvedCommit = try await resolveCommit(
            requestedCommit: commit,
            fallbackCommit: mainline?.commit,
            repositoryPath: expandedPath,
            repositoryName: repo.name
        ) {
            let (ml, _) = await self.refresher.refreshWorkingRepo(repo)
            return ml?.commit
        }
        let content = try await readRawContent(
            path: sanitized,
            commit: resolvedCommit,
            repositoryPath: expandedPath,
            repositoryName: repo.name
        )
        return MainlineFileRead(
            content: content,
            commit: resolvedCommit,
            repository: repo.name,
            path: sanitized,
            ref: mainline?.ref
        )
    }

    /// Reads file content at a mainline commit in a Spec Source.
    public func readFile(
        path: String,
        in specSource: SpecSource,
        commit: String? = nil,
        mainline: ResolvedMainline? = nil,
        repositoryName: String = "spec_source"
    ) async throws -> MainlineFileRead {
        let expandedPath = (specSource.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw MainlineReadError.missingRepository(repository: repositoryName, path: specSource.path)
        }
        let sanitized = try sanitizeRepoRelativePath(path, repositoryPath: expandedPath)
        let resolvedCommit = try await resolveCommit(
            requestedCommit: commit,
            fallbackCommit: mainline?.commit,
            repositoryPath: expandedPath,
            repositoryName: repositoryName
        ) {
            let ml = await self.refresher.resolveSpecSource(specSource)
            return ml?.commit
        }
        let content = try await readRawContent(
            path: sanitized,
            commit: resolvedCommit,
            repositoryPath: expandedPath,
            repositoryName: repositoryName
        )
        return MainlineFileRead(
            content: content,
            commit: resolvedCommit,
            repository: repositoryName,
            path: sanitized,
            ref: mainline?.ref
        )
    }

    /// Reads file content at a mainline commit in a ProjectSpecificationSource.
    public func readFile(
        path: String,
        in specSource: ProjectSpecificationSource,
        commit: String? = nil,
        mainline: ResolvedMainline? = nil
    ) async throws -> MainlineFileRead {
        switch specSource {
        case .specSource(let source):
            return try await readFile(
                path: path,
                in: source,
                commit: commit,
                mainline: mainline,
                repositoryName: specSource.repositoryName
            )
        case .workingRepo(let repo):
            return try await readFile(
                path: path,
                in: repo,
                commit: commit,
                mainline: mainline
            )
        }
    }

    /// Reads file content at a mainline commit for any repository configured in `projectRepositories`.
    public func readFile(
        path: String,
        repository: String,
        in projectRepositories: ProjectRepositories,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async throws -> MainlineFileRead {
        if let repo = projectRepositories.workingRepos.first(where: {
            $0.name == repository || ($0.path as NSString).expandingTildeInPath == (repository as NSString).expandingTildeInPath
        }) {
            let mainline = mainlines?[repo.name]
            return try await readFile(path: path, in: repo, commit: commit, mainline: mainline)
        }

        let isSpecName = repository == "spec_source" || repository == "spec"
            || (projectRepositories.specSource.map { ($0.path as NSString).expandingTildeInPath == (repository as NSString).expandingTildeInPath } ?? false)

        if isSpecName {
            switch projectRepositories.specificationSourceLookup {
            case .resolved(let source):
                let mainline = mainlines?[source.repositoryName] ?? mainlines?.specSource
                return try await readFile(path: path, in: source, commit: commit, mainline: mainline)
            case .none:
                throw MainlineReadError.noSpecificationSource
            case .multiple(let sources):
                throw MainlineReadError.multipleSpecificationSources(sources)
            }
        }

        throw MainlineReadError.unconfiguredRepository(repository)
    }

    // MARK: - Internal Helpers

    func resolveCommit(
        requestedCommit: String?,
        fallbackCommit: String?,
        repositoryPath: String,
        repositoryName: String,
        defaultBranchResolver: () async -> String?
    ) async throws -> String {
        if let requestedCommit, !requestedCommit.isEmpty {
            let result = await git.run([
                "-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(requestedCommit)^{commit}"
            ])
            guard result.isSuccess else {
                throw MainlineReadError.unresolvableCommit(repository: repositoryName, commit: requestedCommit)
            }
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else {
                throw MainlineReadError.unresolvableCommit(repository: repositoryName, commit: requestedCommit)
            }
            return sha
        }

        if let fallbackCommit, !fallbackCommit.isEmpty {
            let result = await git.run([
                "-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(fallbackCommit)^{commit}"
            ])
            guard result.isSuccess else {
                throw MainlineReadError.unresolvableCommit(repository: repositoryName, commit: fallbackCommit)
            }
            let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty else {
                throw MainlineReadError.unresolvableCommit(repository: repositoryName, commit: fallbackCommit)
            }
            return sha
        }

        guard let resolved = await defaultBranchResolver() else {
            throw MainlineReadError.unresolvableMainline(
                repository: repositoryName,
                reason: "Could not resolve mainline HEAD commit"
            )
        }
        return resolved
    }

    func readRawContent(
        path: String,
        commit: String,
        repositoryPath: String,
        repositoryName: String
    ) async throws -> String {
        let catResult = await git.run(["-C", repositoryPath, "cat-file", "-e", "\(commit):\(path)"])
        guard catResult.isSuccess else {
            throw MainlineReadError.fileNotFound(path: path, commit: commit, repository: repositoryName)
        }

        let showResult = await git.run(["-C", repositoryPath, "show", "\(commit):\(path)"])
        guard showResult.isSuccess else {
            let stderr = showResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MainlineReadError.gitError(stderr.isEmpty ? "Failed to read \(path) at \(commit)" : stderr)
        }
        return showResult.stdout
    }
}
