import Domain
import Foundation

/// What a lookup of a Feature Branch's tip found in the main repository.
public enum FeatureBranchTipLookup: Equatable, Sendable {
    /// The branch exists; this is its tip commit.
    case commit(String)
    /// The repository is readable and has no such branch.
    case absent
    /// git could not answer: the repository is missing or unreadable, or git failed. The reason says why.
    case failed(String)
}

/// What a lookup of one commit object in the main repository found.
public enum CommitObjectLookup: Equatable, Sendable {
    /// The object store holds the commit (an unreachable one does until `git gc` prunes it).
    case present
    /// The repository is readable and holds no such commit.
    case absent
    /// git could not answer: the repository is missing or unreadable, or git failed. The reason says why.
    case failed(String)
}

/// Pins a Feature Branch's tip under `refs/yellowhammer/recovery/<branch>` so it survives the removal of
/// the Worktree that checked the branch out (OQ123).
///
/// Orca ADE deletes a removed Worktree's checked-out local branch, asynchronously, and never touches a
/// ref outside `refs/heads/`. Before the land Act the Feature Branch is unpushed, so a ghost-Worktree
/// purge would otherwise lose every commit of the Feature's Done Cards in that repository. Every lookup
/// runs against the MAIN repository — a ghost Worktree's directory is gone. Branch names may carry an
/// Orca ADE prefix containing `/`, so every ref is fully qualified. Local git, not behind a Port.
public struct FeatureBranchRecoveryPin: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The pin ref for `branch`.
    public static func ref(for branch: FeatureBranch) -> String {
        "refs/yellowhammer/recovery/\(branch.name)"
    }

    /// The tip of `branch` in the repository at `repositoryPath`. Tells "the branch does not exist" apart
    /// from "git failed": the repository is verified first, so a missing or corrupt repository is
    /// `.failed` rather than a branch that looks absent — absence is what lets a purge run unpinned.
    public func tip(of branch: FeatureBranch, repositoryPath: String) async -> FeatureBranchTipLookup {
        let repository = await git.run(["-C", repositoryPath, "rev-parse", "--git-dir"])
        guard repository.isSuccess else {
            return .failed(Self.reason(of: repository, fallback: "\(repositoryPath) is not a git repository"))
        }

        let result = await git.run([
            "-C", repositoryPath, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch.name)^{commit}"
        ])
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isSuccess, !sha.isEmpty {
            return .commit(sha)
        }
        if result.exitCode == 1, sha.isEmpty {
            return .absent
        }
        return .failed(Self.reason(of: result, fallback: "git rev-parse exited \(result.exitCode)"))
    }

    /// Whether the commit `sha` is still in the object store of the repository at `repositoryPath`,
    /// reachable or not (OQ133): the way a branch already deleted by Orca ADE may still be recovered from
    /// the Journal's `last_known_good_commit`. The repository is verified first, as in ``tip(of:repositoryPath:)``,
    /// so a missing or corrupt repository is `.failed` rather than a commit that looks pruned.
    public func commitExists(_ sha: String, repositoryPath: String) async -> CommitObjectLookup {
        let repository = await git.run(["-C", repositoryPath, "rev-parse", "--git-dir"])
        guard repository.isSuccess else {
            return .failed(Self.reason(of: repository, fallback: "\(repositoryPath) is not a git repository"))
        }

        let result = await git.run(["-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(sha)^{commit}"])
        if result.isSuccess {
            return .present
        }
        if result.exitCode == 1, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .absent
        }
        return .failed(Self.reason(of: result, fallback: "git rev-parse exited \(result.exitCode)"))
    }

    /// Writes the pin for `branch` at `commit`. True when git accepted it.
    public func pin(_ commit: String, branch: FeatureBranch, repositoryPath: String) async -> Bool {
        let result = await git.run(["-C", repositoryPath, "update-ref", Self.ref(for: branch), commit])
        return result.isSuccess
    }

    /// The commit the pin for `branch` points at, nil when there is no pin.
    public func pinnedCommit(branch: FeatureBranch, repositoryPath: String) async -> String? {
        let result = await git.run([
            "-C", repositoryPath, "rev-parse", "--verify", "--quiet", "\(Self.ref(for: branch))^{commit}"
        ])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Deletes the pin for `branch`, only while it still points at `commit`: git's old-value guard means a
    /// pin that moved is never deleted. True when the pin is gone.
    public func unpin(_ commit: String, branch: FeatureBranch, repositoryPath: String) async -> Bool {
        let result = await git.run(["-C", repositoryPath, "update-ref", "-d", Self.ref(for: branch), commit])
        return result.isSuccess
    }

    /// Polls until `refs/heads/<branch>` no longer exists in the repository, or `timeout` passes; true when
    /// it is gone. Orca ADE deletes the branch asynchronously after `worktree rm` returns — seconds, and
    /// one probe case took more than 10 s. If re-allocation in the same build Act asked Orca ADE for
    /// `--name X` while `refs/heads/X` still existed, Orca ADE would silently make `X-2`, which reads as a
    /// name collision and halts the Act with a misleading remedy.
    public func waitUntilBranchGone(
        _ branch: FeatureBranch, repositoryPath: String, timeout: Duration, interval: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let result = await git.run([
                "-C", repositoryPath, "show-ref", "--verify", "--quiet", "refs/heads/\(branch.name)"
            ])
            if !result.isSuccess {
                return true
            }
            guard clock.now < deadline else {
                return false
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return false
            }
        }
    }

    private static func reason(of result: GitCommandResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? fallback : stderr
    }
}
