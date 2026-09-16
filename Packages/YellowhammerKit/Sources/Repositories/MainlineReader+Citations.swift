import Domain
import Foundation

extension MainlineReader {

    /// Resolves a SpecCitation against a Project's specification source.
    public func resolveCitation(
        _ citation: SpecCitation,
        in projectRepositories: ProjectRepositories,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async -> SpecCitationResolution {
        switch projectRepositories.specificationSourceLookup {
        case .none:
            return .unresolved(
                citation: citation,
                reason: "Project has no specification source configured."
            )
        case .multiple(let sources):
            let joined = sources.joined(separator: ", ")
            return .unresolved(
                citation: citation,
                reason: "Project has multiple specification sources configured: \(joined). Exactly one is required."
            )
        case .resolved(let source):
            let mainline = mainlines?[source.repositoryName] ?? mainlines?.specSource
            return await resolveCitation(
                citation,
                in: source,
                commit: commit,
                mainline: mainline
            )
        }
    }

    /// Resolves a SpecCitation against a ProjectSpecificationSource.
    public func resolveCitation(
        _ citation: SpecCitation,
        in specSource: ProjectSpecificationSource,
        commit: String? = nil,
        mainline: ResolvedMainline? = nil
    ) async -> SpecCitationResolution {
        let repoPath = (specSource.path as NSString).expandingTildeInPath
        let repoName = specSource.repositoryName

        guard FileManager.default.fileExists(atPath: repoPath) else {
            return .unresolved(
                citation: citation,
                reason: "Specification source repository does not exist at '\(specSource.path)'",
                repository: repoName
            )
        }

        let resolvedCommit: String
        do {
            resolvedCommit = try await resolveCommit(
                requestedCommit: commit,
                fallbackCommit: mainline?.commit,
                repositoryPath: repoPath,
                repositoryName: repoName
            ) {
                switch specSource {
                case .specSource(let source):
                    return await self.refresher.resolveSpecSource(source)?.commit
                case .workingRepo(let repo):
                    return await self.refresher.refreshWorkingRepo(repo).mainline?.commit
                }
            }
        } catch {
            return .unresolved(
                citation: citation,
                reason: "Could not resolve mainline commit: \(error.localizedDescription)",
                repository: repoName
            )
        }

        return await performCitationResolution(
            citation: citation,
            repoPath: repoPath,
            repoName: repoName,
            commit: resolvedCommit
        )
    }

    /// Resolves a SpecCitation against a SpecSource.
    public func resolveCitation(
        _ citation: SpecCitation,
        in specSource: SpecSource,
        commit: String? = nil,
        mainline: ResolvedMainline? = nil,
        repositoryName: String = "spec_source"
    ) async -> SpecCitationResolution {
        await resolveCitation(
            citation,
            in: .specSource(specSource),
            commit: commit,
            mainline: mainline
        )
    }

    /// Resolves a SpecCitation against a working Repo.
    public func resolveCitation(
        _ citation: SpecCitation,
        in repo: Repo,
        commit: String? = nil,
        mainline: ResolvedMainline? = nil
    ) async -> SpecCitationResolution {
        await resolveCitation(
            citation,
            in: .workingRepo(repo),
            commit: commit,
            mainline: mainline
        )
    }

    /// Resolves a SpecCitation string against a Project's configuration.
    public func resolveCitation(
        _ citation: String,
        in projectRepositories: ProjectRepositories,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async -> SpecCitationResolution {
        await resolveCitation(
            SpecCitation(citation),
            in: projectRepositories,
            commit: commit,
            mainlines: mainlines
        )
    }

    /// Predicate returning whether a citation resolves against a Project's specification source.
    public func resolvesCitation(
        _ citation: SpecCitation,
        in projectRepositories: ProjectRepositories,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async -> Bool {
        await resolveCitation(citation, in: projectRepositories, commit: commit, mainlines: mainlines).resolves
    }

    /// Predicate returning whether a citation string resolves against a Project's specification source.
    public func resolvesCitation(
        _ citation: String,
        in projectRepositories: ProjectRepositories,
        commit: String? = nil,
        mainlines: ResolvedMainlines? = nil
    ) async -> Bool {
        await resolvesCitation(SpecCitation(citation), in: projectRepositories, commit: commit, mainlines: mainlines)
    }

    // MARK: - Private Citation Helpers

    private func performCitationResolution(
        citation: SpecCitation,
        repoPath: String,
        repoName: String,
        commit: String
    ) async -> SpecCitationResolution {
        let raw = citation.rawValue
        let isGoalCandidate = raw.range(of: "^[Gg]\\d+$", options: .regularExpression) != nil
            || raw.hasPrefix("{#")
            || raw.hasPrefix("#")
            || raw.contains("goals")

        if isGoalCandidate {
            if let res = await attemptGoalResolution(
                citation: citation,
                repoPath: repoPath,
                repoName: repoName,
                commit: commit
            ) {
                return res
            }
        }

        if raw.contains("/") {
            if let res = await attemptStoryResolution(
                citation: citation,
                repoPath: repoPath,
                repoName: repoName,
                commit: commit
            ) {
                return res
            }
        }

        if !isGoalCandidate {
            if let res = await attemptGoalResolution(
                citation: citation,
                repoPath: repoPath,
                repoName: repoName,
                commit: commit
            ) {
                return res
            }
        }

        return .unresolved(
            citation: citation,
            reason: "Citation '\(raw)' could not be resolved in specification repository '\(repoName)'",
            repository: repoName,
            commit: commit
        )
    }

    private static let candidateGoalsPaths = [
        "docs/requirements/vision/goals.md",
        "requirements/vision/goals.md",
        "vision/goals.md",
        "docs/vision/goals.md",
        "docs/goals.md",
        "goals.md"
    ]

    private func attemptGoalResolution(
        citation: SpecCitation,
        repoPath: String,
        repoName: String,
        commit: String
    ) async -> SpecCitationResolution? {
        for candidate in Self.candidateGoalsPaths {
            let catResult = await git.run(["-C", repoPath, "cat-file", "-e", "\(commit):\(candidate)"])
            guard catResult.isSuccess else { continue }

            if let content = try? await readRawContent(
                path: candidate,
                commit: commit,
                repositoryPath: repoPath,
                repositoryName: repoName
            ), verifyGoalInContent(citation: citation.rawValue, content: content) {
                return .resolved(
                    citation: citation,
                    resolvedPath: candidate,
                    commit: commit,
                    repository: repoName
                )
            }
        }
        return nil
    }

    private func verifyGoalInContent(citation: String, content: String) -> Bool {
        var anchor = citation
        if anchor.hasPrefix("{#") && anchor.hasSuffix("}") {
            anchor = String(anchor.dropFirst(2).dropLast(1))
        } else if anchor.hasPrefix("#") {
            anchor = String(anchor.dropFirst(1))
        } else if let hashIndex = anchor.firstIndex(of: "#") {
            anchor = String(anchor[anchor.index(after: hashIndex)...])
        }

        let lowerAnchor = anchor.lowercased()
        let lowerContent = content.lowercased()

        if lowerContent.contains("{#\(lowerAnchor)}") || lowerContent.contains("{#\(lowerAnchor) ") {
            return true
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let lowerTrimmed = trimmed.lowercased()

            if lowerTrimmed.contains("{#\(lowerAnchor)}") {
                return true
            }

            if lowerTrimmed.contains(" \(lowerAnchor):")
                || lowerTrimmed.contains(" \(lowerAnchor) ")
                || lowerTrimmed.hasSuffix(" \(lowerAnchor)") {
                return true
            }
            if lowerTrimmed.contains("`\(lowerAnchor)`") {
                return true
            }
        }

        return false
    }

    private func attemptStoryResolution(
        citation: SpecCitation,
        repoPath: String,
        repoName: String,
        commit: String
    ) async -> SpecCitationResolution? {
        let raw = citation.rawValue
        let parts = raw.split(separator: "/")
        guard parts.count >= 2 else { return nil }

        let epic = String(parts[0])
        var story = String(parts[parts.count - 1])
        if story.hasSuffix(".md") {
            story = String(story.dropLast(3))
        }
        if let hashIdx = story.firstIndex(of: "#") {
            story = String(story[..<hashIdx])
        }

        let candidates = candidateStoryPaths(epic: epic, story: story, rawCitation: raw)
        for candidate in candidates {
            let res = await git.run(["-C", repoPath, "cat-file", "-e", "\(commit):\(candidate)"])
            if res.isSuccess {
                return .resolved(
                    citation: citation,
                    resolvedPath: candidate,
                    commit: commit,
                    repository: repoName
                )
            }
        }
        return nil
    }

    private func candidateStoryPaths(epic: String, story: String, rawCitation: String) -> [String] {
        var paths: [String] = []
        if rawCitation.hasSuffix(".md") {
            paths.append(rawCitation)
        }
        paths.append("docs/requirements/epics/\(epic)/stories/\(story).md")
        paths.append("requirements/epics/\(epic)/stories/\(story).md")
        paths.append("epics/\(epic)/stories/\(story).md")
        paths.append("docs/epics/\(epic)/stories/\(story).md")
        paths.append("specs/epics/\(epic)/stories/\(story).md")
        paths.append("docs/requirements/epics/\(epic)/\(story).md")
        paths.append("requirements/\(epic)/stories/\(story).md")
        paths.append("docs/\(epic)/\(story).md")
        paths.append("\(epic)/stories/\(story).md")
        paths.append("\(epic)/\(story).md")
        if !paths.contains(rawCitation) {
            paths.append(rawCitation)
        }
        return paths
    }
}
