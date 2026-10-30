import Domain
import Foundation

/// What writing or deleting a landed-tip pin did.
public enum LandedPinResult: Equatable, Sendable {
    /// git accepted it; for a delete, the ref is gone (including when it was already absent).
    case done
    /// git could not do it; the reason says why.
    case failed(String)
}

/// Pins the commit the land Act pushed for a Feature Branch under `refs/yellowhammer/landed/<branch>`, in the
/// repository's MAIN clone, so the commit survives Orca ADE, GitHub or an Operator fetch deleting every
/// branch ref, and `git gc` (feature-authoring/select-the-next-feature, OQ164). The predecessor gate tests
/// that commit; the Journal records it as the Pushed Tip (`JournalStore.recordPushedTip`).
///
/// Branch names may carry an Orca ADE prefix containing `/`, so the ref is always fully qualified. Every call
/// runs against the main repository path from the Project's `Repo`, never a Worktree. Local git, not behind a
/// Port.
public struct LandedTipPin: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The pin ref for `branch`.
    public static func ref(for branch: FeatureBranch) -> String {
        "refs/yellowhammer/landed/\(branch.name)"
    }

    /// Writes the pin for `branch` at `commit`, moving it if the branch was pushed again.
    public func pin(commit: String, branch: FeatureBranch, repositoryPath: String) async -> LandedPinResult {
        let result = await git.run(["-C", repositoryPath, "update-ref", Self.ref(for: branch), commit])
        return Self.outcome(of: result)
    }

    /// Deletes the pin for `branch`. A pin that is already absent is success: abandoning twice, or after the
    /// Operator pruned the ref, is not a failure. The repository is verified first, so a missing or corrupt
    /// repository is `.failed` rather than a pin that looks absent.
    public func unpin(branch: FeatureBranch, repositoryPath: String) async -> LandedPinResult {
        let repository = await git.run(["-C", repositoryPath, "rev-parse", "--git-dir"])
        guard repository.isSuccess else {
            return .failed(Self.reason(of: repository, fallback: "\(repositoryPath) is not a git repository"))
        }

        let ref = Self.ref(for: branch)
        let existing = await git.run(["-C", repositoryPath, "show-ref", "--verify", "--quiet", ref])
        if !existing.isSuccess, existing.exitCode == 1 {
            return .done
        }

        let result = await git.run(["-C", repositoryPath, "update-ref", "-d", ref])
        return Self.outcome(of: result)
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

    private static func outcome(of result: GitCommandResult) -> LandedPinResult {
        result.isSuccess ? .done : .failed(reason(of: result, fallback: "git update-ref exited \(result.exitCode)"))
    }

    private static func reason(of result: GitCommandResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? fallback : stderr
    }
}
