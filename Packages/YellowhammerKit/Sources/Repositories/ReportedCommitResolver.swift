import Foundation

/// What a worker-reported commit names in a Worktree, read with the local `git` executable (issue #727).
public enum ReportedCommitResolution: Equatable, Sendable {
    /// The reported value resolves to a commit: `commit` is git's full object name for it, so a short
    /// sha is widened to the full one.
    case resolved(commit: String)
    /// The reported value names no commit in the Worktree; `head` is the Worktree's HEAD, used in its place.
    case substitutedHead(head: String)
    /// Neither the reported value nor HEAD resolves (not a git work tree, or one with no commit yet). The
    /// caller keeps the reported value; reading it fails later and is recorded there.
    case unresolvable
}

/// Resolves the commit a worker reported in its result file against the Worktree it ran in. The report is
/// model-authored: on the 2026-10-31 Night a worker reported a 40-character hash that shares only its
/// first 8 characters with its real commit, and the engine recorded and judged that non-object.
public struct ReportedCommitResolver: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// `git rev-parse --verify <reported>^{commit}` in `worktreePath`; when that fails, the Worktree's
    /// HEAD. A reported value that is not a hexadecimal object name is never handed to git, so it can name
    /// neither a ref nor an option: it falls through to HEAD like any other unresolvable report.
    public func resolve(_ reported: String, worktreePath: String) async -> ReportedCommitResolution {
        if Self.isObjectName(reported), let commit = await commit(naming: reported, in: worktreePath) {
            return .resolved(commit: commit)
        }
        if let head = await commit(naming: "HEAD", in: worktreePath) {
            return .substitutedHead(head: head)
        }
        return .unresolvable
    }

    private func commit(naming name: String, in path: String) async -> String? {
        let result = await git.run([
            "-C", path, "rev-parse", "--verify", "--quiet", "--end-of-options", "\(name)^{commit}"
        ])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// A hexadecimal object name, abbreviated (git's minimum is 4) or full (SHA-1 or SHA-256).
    private static func isObjectName(_ value: String) -> Bool {
        (4...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}
