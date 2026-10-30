import Domain
import Foundation

/// An Operator-edited Transcription Block reference that cannot be read
/// (spec: feature-authoring/author-an-architectural-brief#edited-reference). The reasons
/// ``MainlineReader/transcribe(paths:ranges:repository:in:symbol:commit:mainlines:)`` already gives —
/// an unconfigured repository, an unresolvable commit, a path that is not a regular file, a range out of
/// bounds — propagate as their own errors; these are the two it does not.
public enum EditedReferenceError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The edited reference names no commit, so there is nothing to read it at.
    case noCommit
    /// The commit resolves, but is neither the repository's local mainline head nor one of its ancestors.
    case notOnMainline(repository: String, commit: String, mainlineCommit: String)
    /// Whether the commit is on mainline could not be tested (no mainline head, or git failed).
    case ancestryUntestable(repository: String, reason: String)

    public var description: String {
        switch self {
        case .noCommit:
            return "it names no commit"
        case .notOnMainline(let repository, let commit, let mainlineCommit):
            return "commit \(GitCommit.short(commit)) is not on \(repository)'s mainline "
                + "(mainline at \(GitCommit.short(mainlineCommit)))"
        case .ancestryUntestable(let repository, let reason):
            return "whether the commit is on \(repository)'s mainline could not be tested: \(reason)"
        }
    }
}

extension MainlineReader {
    /// Reads an Operator-edited Transcription Block reference from local mainline, at the commit it names.
    ///
    /// The commit must be the repository's local mainline head or one of its ancestors; a side-branch
    /// commit is refused. Every other failure is the one
    /// ``transcribe(paths:ranges:repository:in:symbol:commit:mainlines:)`` throws. The returned block is
    /// not marked Operator-supplied — the caller records the read and keeps the label it already has.
    public func readEditedReference(
        repository: String,
        paths: [String],
        ranges: [String: [LineRange]] = [:],
        symbol: String? = nil,
        commit: String?,
        in projectRepositories: ProjectRepositories,
        mainlines: ResolvedMainlines? = nil
    ) async throws -> TranscriptionBlock {
        let trimmed = commit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw EditedReferenceError.noCommit }

        let block = try await transcribe(
            paths: paths, ranges: ranges, repository: repository, in: projectRepositories,
            symbol: symbol, commit: trimmed, mainlines: mainlines
        )
        guard let resolved = block.mainlineCommit, !resolved.isEmpty else {
            throw EditedReferenceError.ancestryUntestable(repository: repository, reason: "the commit did not resolve")
        }

        guard let target = Self.editedReferenceTarget(repository, in: projectRepositories, mainlines: mainlines) else {
            throw MainlineReadError.unconfiguredRepository(repository)
        }
        guard let head = await mainlineHead(of: target) else {
            throw EditedReferenceError.ancestryUntestable(
                repository: target.name, reason: "its mainline head could not be resolved"
            )
        }

        let result = await git.run(["-C", target.path, "merge-base", "--is-ancestor", resolved, head])
        switch result.exitCode {
        case 0:
            return block
        case 1:
            throw EditedReferenceError.notOnMainline(repository: target.name, commit: resolved, mainlineCommit: head)
        default:
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw EditedReferenceError.ancestryUntestable(
                repository: target.name, reason: stderr.isEmpty ? "git exited \(result.exitCode)" : stderr
            )
        }
    }
}

// MARK: - Locating the repository

/// The repository an edited reference names: where it is on disk, and where its mainline head comes from.
private struct EditedReferenceTarget {
    let name: String
    let path: String
    /// The mainline the caller pinned for this repository, if any.
    let pinned: ResolvedMainline?
    let source: Source

    enum Source {
        case working(Repo)
        case spec(SpecSource)
    }
}

extension MainlineReader {
    /// Matches `repository` the way ``readFile(path:repository:in:commit:mainlines:)`` does: a working
    /// repository by name or path, else the Project's one specification source by `spec_source`, `spec` or path.
    fileprivate static func editedReferenceTarget(
        _ repository: String, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines?
    ) -> EditedReferenceTarget? {
        let expanded = (repository as NSString).expandingTildeInPath
        if let repo = projectRepositories.workingRepos.first(where: {
            $0.name == repository || ($0.path as NSString).expandingTildeInPath == expanded
        }) {
            return EditedReferenceTarget(
                name: repo.name, path: (repo.path as NSString).expandingTildeInPath,
                pinned: mainlines?[repo.name], source: .working(repo)
            )
        }
        let isSpecName = repository == "spec_source" || repository == "spec"
            || (projectRepositories.specSource.map { ($0.path as NSString).expandingTildeInPath == expanded } ?? false)
        guard isSpecName, case .resolved(let source) = projectRepositories.specificationSourceLookup else {
            return nil
        }
        let pinned = mainlines?[source.repositoryName] ?? mainlines?.specSource
        switch source {
        case .specSource(let spec):
            return EditedReferenceTarget(
                name: source.repositoryName, path: (spec.path as NSString).expandingTildeInPath,
                pinned: pinned, source: .spec(spec)
            )
        case .workingRepo(let repo):
            return EditedReferenceTarget(
                name: repo.name, path: (repo.path as NSString).expandingTildeInPath,
                pinned: pinned, source: .working(repo)
            )
        }
    }

    /// The target's local mainline head: the pinned one when the caller has it, else resolved the way
    /// ``readFile(path:in:commit:mainline:)`` falls back — through the refresher.
    fileprivate func mainlineHead(of target: EditedReferenceTarget) async -> String? {
        if let commit = target.pinned?.commit, !commit.isEmpty { return commit }
        switch target.source {
        case .working(let repo):
            return await refresher.refreshWorkingRepo(repo).mainline?.commit
        case .spec(let spec):
            return await refresher.resolveSpecSource(spec)?.commit
        }
    }
}
