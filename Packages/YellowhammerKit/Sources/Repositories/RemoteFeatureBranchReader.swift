import Domain
import Foundation

/// What a remote Feature Branch is at, read from the remote itself before a pull request opens (OQ191 item 4;
/// landing/open-one-pull-request-per-repository `#remote-tip-check`).
public enum RemoteFeatureBranchTip: Equatable, Sendable {
    /// The remote has the branch, at `commit`.
    case at(commit: String)
    /// The remote was read and has no such branch.
    case absent
    /// The remote could not be read; `reason` is git's own one-line account, never a credential.
    case unreadable(reason: String)
}

/// Reads the commit a Feature Branch is at on its GitHub remote with `git ls-remote`, through the same remote and
/// credential the push uses (``FeatureBranchPusher``): with a credential, the HTTPS URL derived from a GitHub
/// `origin`, authenticated by environment-only config; without one, or for an `origin` not on GitHub, `origin` as
/// configured. Never reads `refs/remotes/origin/<branch>`: that is a local copy the push updates best-effort, and
/// it does not move when the remote does.
public struct RemoteFeatureBranchReader: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// `branch` on the remote of the repository at `path`.
    public func read(
        branch: FeatureBranch, in path: String, credential: PushCredential?
    ) async -> RemoteFeatureBranchTip {
        let ref = "refs/heads/\(branch.name)"
        let httpsURL = await git.httpsURL(for: credential, in: path)
        // Always authenticated, even with no credential: it disables every terminal and askpass prompt.
        let runner = git.authenticated(with: credential, httpsURL: httpsURL)
        let result = await runner.run(["-C", path, "ls-remote", "--heads", httpsURL ?? "origin", ref])
        guard result.isSuccess else {
            return .unreadable(reason: Self.reason(result))
        }
        // ls-remote matches its pattern on a path-component suffix: keep only the exact ref.
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", maxSplits: 1)
            if columns.count == 2, columns[1] == ref {
                return .at(commit: String(columns[0]))
            }
        }
        return .absent
    }

    /// git's first non-empty stderr line, kept short; the exit code when git said nothing.
    private static func reason(_ result: GitCommandResult) -> String {
        let line = result.stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return "git ls-remote exited \(result.exitCode)" }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}
