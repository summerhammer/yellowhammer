import Foundation
import Subprocess
import System

/// What importing a GitHub token from the GitHub CLI (`gh auth token`) gave.
enum GitHubTokenImport: Equatable, Sendable {
    case token(String)
    /// No token: `gh` is not installed, is not logged in, or printed nothing. The reason names no secret.
    case unavailable(String)
}

extension GitHubTokenImport {
    /// Runs `gh auth token --hostname github.com` and reads the token from its standard output. The token is
    /// never a process argument, and `gh`'s standard error is discarded.
    static func production(
        path: String?, fileExists: @escaping @Sendable (String) -> Bool
    ) -> @Sendable () async -> GitHubTokenImport {
        {
            guard let executable = GitHubCLIExecutable.resolve(
                declared: nil, path: path, fileExists: fileExists
            ) else {
                return .unavailable("the GitHub CLI (gh) was not found on PATH, /opt/homebrew/bin or /usr/local/bin")
            }
            do {
                let result = try await Subprocess.run(
                    .path(FilePath(executable)), arguments: ["auth", "token", "--hostname", "github.com"],
                    input: .none, output: .string(limit: 64 * 1024), error: .discarded
                )
                guard case .exited(0) = result.terminationStatus else {
                    return .unavailable("gh auth token failed; run `gh auth login` first")
                }
                let token = (result.standardOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? .unavailable("gh auth token printed nothing; run `gh auth login` first")
                    : .token(token)
            } catch {
                return .unavailable("the GitHub CLI (gh) could not be run")
            }
        }
    }
}
