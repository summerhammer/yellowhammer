import Darwin
import Domain
import Foundation

/// Current-user-only local storage for dispatch prompt records.
///
/// Restricts prompt directories and files to mode 0700/0600 owned by the current macOS user.
public struct DispatchPromptStore: DispatchPromptRecording, Sendable {
    public let rootDirectory: URL
    public let currentUser: uid_t
    public let now: @Sendable () -> Date

    public init(
        rootDirectory: URL,
        currentUser: uid_t = getuid(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.currentUser = currentUser
        self.now = now
    }

    /// `<configuration directory>/prompts`.
    public static func rootDirectory(configurationDirectory: URL) -> URL {
        configurationDirectory.appending(component: "prompts")
    }

    /// Scope directory URL for a given scope.
    public func directory(for scope: DispatchPromptScope) -> URL {
        switch scope {
        case .project(let projectID):
            rootDirectory.appending(components: "projects", projectID.rawValue, directoryHint: .isDirectory)
        case .machine:
            rootDirectory.appending(components: "machine", directoryHint: .isDirectory)
        }
    }

    /// Validates an identifier string. Refuses empty strings, `/`, or `..`.
    func validateIdentifier(_ id: String, name: String) -> String? {
        if id.isEmpty {
            return "\(name) is empty"
        }
        if id == "." || id.contains("/") || id.contains("..") {
            return "\(name) contains invalid path components: \"\(id)\""
        }
        return nil
    }
}

/// Seam for cleaning recorded prompts during Project removal.
public protocol DispatchPromptCleaning: Sendable {
    func removeAll(projectID: ProjectID) throws
}

extension DispatchPromptStore: DispatchPromptCleaning {}

/// Errors raised by `DispatchPromptStore` mutation operations.
public enum DispatchPromptStoreError: Error, Sendable, CustomStringConvertible {
    case invalidIdentifier(String)
    case directoryRemovalFailed(URL, String)

    public var description: String {
        switch self {
        case .invalidIdentifier(let reason):
            "invalid identifier: \(reason)"
        case .directoryRemovalFailed(let url, let reason):
            "failed to remove directory at \(url.path(percentEncoded: false)): \(reason)"
        }
    }
}

struct RestrictionError: Error {
    let message: String
}
