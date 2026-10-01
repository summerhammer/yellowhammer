import Domain
import Foundation

/// The outcome of attempting a WIP commit in a Worktree.
public enum WIPCommitOutcome: Equatable, Sendable {
    /// A WIP commit was created and the WIP ref now points at it.
    case committed(commit: String, wipRef: String)
    /// The Worktree had nothing to commit; no commit was written. Carries the current HEAD and,
    /// if one already exists, the standing WIP ref and the commit it resolves to.
    case noChanges(headCommit: String, wipRef: String?, wipCommit: String?)
    /// Refused without writing anything: the Worktree is missing, or HEAD is not the Feature Branch.
    case refused(reason: String)
    /// A git invocation failed unexpectedly.
    case failed(reason: String)
}

/// Commits any dirty state in a Feature Branch's Worktree as a WIP commit, and keeps a stable
/// `refs/yellowhammer/wip/<branch>` ref pointing at the latest one.
///
/// Never runs on a Worktree that is not checked out to its own Feature Branch, never rewrites a
/// commit that already exists, and never creates a second WIP commit for an already-clean tree.
public struct WorktreeCommitter: Sendable {
    public let git: GitRunner
    /// A rehearsal Night never commits into a Worktree (system-overview, Environment Differences):
    /// `commitWIP` refuses on a dirty tree instead of writing a WIP commit.
    public let mode: NightMode

    /// What every WIP commit this committer writes says, and the author it is written as.
    public let message: WIPCommitMessage

    public init(git: GitRunner = GitRunner(), mode: NightMode = .real, message: WIPCommitMessage = WIPCommitMessage()) {
        self.git = git
        self.mode = mode
        self.message = message
    }

    /// Commits any uncommitted changes (tracked and untracked) in the Worktree as a WIP commit.
    /// `repository` fills the template's `{repository}` token.
    public func commitWIP(worktreePath: String, branch: FeatureBranch, repository: String) async -> WIPCommitOutcome {
        let path = (worktreePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return .refused(reason: "Worktree path does not exist: \(worktreePath)")
        }

        let expectedRef = "refs/heads/\(branch.name)"
        guard let currentRef = await symbolicHeadRef(in: path) else {
            return .refused(reason: "HEAD is not on Feature Branch \(branch.name): HEAD is detached")
        }
        guard currentRef == expectedRef else {
            return .refused(reason: "HEAD is not on Feature Branch \(branch.name): HEAD is \(currentRef)")
        }

        let wipRef = "refs/yellowhammer/wip/\(branch.name)"

        let status = await git.run(["-C", path, "status", "--porcelain", "--untracked-files=all"])
        guard status.isSuccess else {
            return .failed(reason: "git status exited \(status.exitCode): \(trimmed(status.stderr))")
        }

        if trimmed(status.stdout).isEmpty {
            guard let headCommit = await revParse("HEAD", in: path) else {
                return .failed(reason: "could not resolve HEAD")
            }
            let wipCommit = await revParse(wipRef, in: path)
            return .noChanges(headCommit: headCommit, wipRef: wipCommit != nil ? wipRef : nil, wipCommit: wipCommit)
        }

        if mode == .rehearsal {
            return .refused(
                reason: "a rehearsal Night never commits into a Worktree; uncommitted changes were left in place"
            )
        }

        return await commitDirtyTree(at: path, branch: branch, repository: repository, wipRef: wipRef)
    }

    /// Writes the WIP commit itself, once the tree is known dirty and eligible to commit (real mode).
    private func commitDirtyTree(
        at path: String, branch: FeatureBranch, repository: String, wipRef: String
    ) async -> WIPCommitOutcome {
        let add = await git.run(["-C", path, "add", "-A"])
        guard add.isSuccess else {
            return .failed(reason: "git add exited \(add.exitCode): \(trimmed(add.stderr))")
        }

        let wipMessage = message.render(branch: branch, repository: repository)
        let commit = await git.run([
            "-c", "user.name=\(WIPCommitMessage.authorName)",
            "-c", "user.email=\(WIPCommitMessage.authorEmail)",
            "-c", "commit.gpgsign=false",
            "-C", path,
            "commit",
            "--no-verify",
            "-m", wipMessage
        ])
        guard commit.isSuccess else {
            return .failed(reason: "git commit exited \(commit.exitCode): \(trimmed(commit.stderr))")
        }

        guard let commitSHA = await revParse("HEAD", in: path) else {
            return .failed(reason: "could not resolve HEAD after commit")
        }

        let updateRef = await git.run(["-C", path, "update-ref", wipRef, commitSHA])
        guard updateRef.isSuccess else {
            return .failed(reason: "git update-ref exited \(updateRef.exitCode): \(trimmed(updateRef.stderr))")
        }

        return .committed(commit: commitSHA, wipRef: wipRef)
    }

    private func symbolicHeadRef(in path: String) async -> String? {
        let result = await git.run(["-C", path, "symbolic-ref", "-q", "HEAD"])
        guard result.isSuccess else { return nil }
        let ref = trimmed(result.stdout)
        return ref.isEmpty ? nil : ref
    }

    private func revParse(_ ref: String, in path: String) async -> String? {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
        guard result.isSuccess else { return nil }
        let sha = trimmed(result.stdout)
        return sha.isEmpty ? nil : sha
    }

    private func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The outcome of attempting to reset a Worktree to a known-good commit.
public enum WorktreeResetOutcome: Equatable, Sendable {
    /// The Feature Branch now points at `to`; `wipRef` is the standing WIP ref, if one exists,
    /// so the caller can hand the WIP commit to a retry.
    case reset(to: String, wipRef: String?)
    /// Refused: nothing was destroyed. Covers a missing or dirty Worktree, HEAD off the Feature
    /// Branch, and an unresolvable known-good commit.
    case refused(reason: String)
    /// A git invocation failed unexpectedly.
    case failed(reason: String)
}

extension WorktreeCommitter {
    /// Resets a Feature Branch's Worktree to a known-good commit.
    ///
    /// Refuses outright if the Worktree has any uncommitted changes: uncommitted work is never
    /// discarded silently. The caller must WIP-commit first, then reset.
    public func resetToKnownGood(
        worktreePath: String,
        branch: FeatureBranch,
        knownGood: String
    ) async -> WorktreeResetOutcome {
        let path = (worktreePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return .refused(reason: "Worktree path does not exist: \(worktreePath)")
        }

        let status = await git.run(["-C", path, "status", "--porcelain", "--untracked-files=all"])
        guard status.isSuccess else {
            return .failed(reason: "git status exited \(status.exitCode): \(trimmed(status.stderr))")
        }
        guard trimmed(status.stdout).isEmpty else {
            return .refused(reason: "Worktree has uncommitted changes; commit WIP before resetting")
        }

        let expectedRef = "refs/heads/\(branch.name)"
        guard let currentRef = await symbolicHeadRef(in: path) else {
            return .refused(reason: "HEAD is not on Feature Branch \(branch.name): HEAD is detached")
        }
        guard currentRef == expectedRef else {
            return .refused(reason: "HEAD is not on Feature Branch \(branch.name): HEAD is \(currentRef)")
        }

        guard let resolvedKnownGood = await revParse(knownGood, in: path) else {
            return .refused(reason: "known-good commit does not resolve: \(knownGood)")
        }

        let reset = await git.run(["-C", path, "reset", "--hard", resolvedKnownGood])
        guard reset.isSuccess else {
            return .failed(reason: "git reset exited \(reset.exitCode): \(trimmed(reset.stderr))")
        }

        let wipRef = "refs/yellowhammer/wip/\(branch.name)"
        let wipRefResolved = await revParse(wipRef, in: path) != nil

        return .reset(to: resolvedKnownGood, wipRef: wipRefResolved ? wipRef : nil)
    }
}
