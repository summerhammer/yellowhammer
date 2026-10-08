import Foundation

/// Where the Operator's GitHub CLI (`gh`) is found at the time of use. Shared by the token import, the `gh`
/// credential checks and the land Act, so they all search the same places.
enum GitHubCLIExecutable {
    /// Directories searched after `PATH`: `launchd` and the app run with a minimal `PATH`, where Homebrew's
    /// `gh` would otherwise not be found.
    static let fixedDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The refusal text when no `gh` is found, shared so every surface says the same thing.
    static let notFoundMessage =
        "the GitHub CLI (gh) was not found on PATH, /opt/homebrew/bin or /usr/local/bin; install it and run "
            + "`gh auth login`, or select a Keychain token connection for the Project"

    /// `gh` was not found; carries ``notFoundMessage``, never a secret.
    struct NotFound: Error, CustomStringConvertible, Sendable {
        var description: String { GitHubCLIExecutable.notFoundMessage }
    }

    /// Resolves `gh` at the time of use for a seam that throws: `declared`, else the process's `PATH` and the
    /// fixed directories. Under `launchd` the process's `PATH` is the LaunchAgent's composed one.
    static let production: @Sendable (String?) throws -> String = { declared in
        guard let executable = resolve(
            declared: declared, path: ProcessInfo.processInfo.environment["PATH"],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        ) else {
            throw NotFound()
        }
        return executable
    }

    /// `declared` when given, else the first `gh` found on `path` and then in ``fixedDirectories``; nil when none.
    static func resolve(declared: String?, path: String?, fileExists: (String) -> Bool) -> String? {
        let searchPath = ([path].compactMap { $0 } + fixedDirectories).joined(separator: ":")
        return ProbeExecutable.resolve(name: "gh", declared: declared, path: searchPath, fileExists: fileExists)
    }
}
