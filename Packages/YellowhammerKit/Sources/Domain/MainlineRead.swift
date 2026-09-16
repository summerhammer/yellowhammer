import Foundation

/// Content read from a mainline commit for a working repository or Spec Source.
///
/// Returned with the exact commit SHA it was read at, touching no working tree,
/// writing no commit, and moving no ref.
public struct MainlineFileRead: Equatable, Sendable {
    public let content: String
    public let commit: String
    public let repository: String
    public let path: String
    public let ref: String?

    public init(
        content: String,
        commit: String,
        repository: String,
        path: String,
        ref: String? = nil
    ) {
        self.content = content
        self.commit = commit
        self.repository = repository
        self.path = path
        self.ref = ref
    }
}

/// Errors arising when attempting to read from a repository's mainline or resolving citations.
public enum MainlineReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case unconfiguredRepository(String)
    case outsideProjectScope(String)
    case pathEscapesRepository(String)
    case missingRepository(repository: String, path: String)
    case unresolvableMainline(repository: String, reason: String)
    case unresolvableCommit(repository: String, commit: String)
    case fileNotFound(path: String, commit: String, repository: String)
    case noSpecificationSource
    case multipleSpecificationSources([String])
    case gitError(String)

    public var description: String {
        switch self {
        case .unconfiguredRepository(let repo):
            return "Repository '\(repo)' is not configured in this Project."
        case .outsideProjectScope(let reason):
            return "Repository read outside Project scope: \(reason)"
        case .pathEscapesRepository(let path):
            return "Path '\(path)' escapes repository root."
        case .missingRepository(let repo, let path):
            return "Repository '\(repo)' directory does not exist at '\(path)'."
        case .unresolvableMainline(let repo, let reason):
            return "Could not resolve mainline for repository '\(repo)': \(reason)"
        case .unresolvableCommit(let repo, let commit):
            return "Commit '\(commit)' could not be resolved in repository '\(repo)'."
        case .fileNotFound(let path, let commit, let repo):
            return "File '\(path)' not found at commit '\(commit)' in repository '\(repo)'."
        case .noSpecificationSource:
            return "Project has no specification source configured."
        case .multipleSpecificationSources(let sources):
            let joined = sources.joined(separator: ", ")
            return "Project has multiple specification sources configured: \(joined). Exactly one is required."
        case .gitError(let message):
            return "Git command failed: \(message)"
        }
    }

    public static func missingRepository(_ path: String) -> MainlineReadError {
        .missingRepository(repository: (path as NSString).lastPathComponent, path: path)
    }
}
