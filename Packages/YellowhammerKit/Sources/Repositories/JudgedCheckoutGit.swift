import Foundation

/// Why a fresh checkout for the verifier could not be made: git's own reason.
public struct FreshCheckoutError: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// The local git the checkout Verification judges needs (spec: verification/verify-a-feature-clause-by-clause,
/// `#judged-checkout`; OQ191 items 2, 5, 7 and 8): whether a held Worktree is exact and clean at its recorded
/// commit, and a fresh checkout of a repository at that commit. Local git, not behind a Port.
public struct JudgedCheckoutGit: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Whether the held Worktree at `worktreePath` is exact — its HEAD is `recordedCommit` (the Pushed Tip, or
    /// the recorded base commit) — and clean: `git status` reports nothing. Ignored files are allowed: they are
    /// the build state the reuse keeps (item 7). A Worktree git cannot read is neither.
    public func isExactAndClean(worktreePath: String, recordedCommit: String) async -> Bool {
        let head = await git.run(["-C", worktreePath, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        guard head.isSuccess, head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == recordedCommit else {
            return false
        }
        return await isClean(worktreePath: worktreePath)
    }

    /// Whether `git status` in the Worktree at `worktreePath` reports nothing (ignored files allowed); false when
    /// git cannot read it. For a caller that already knows HEAD is the recorded commit.
    public func isClean(worktreePath: String) async -> Bool {
        let status = await git.run(["-C", worktreePath, "status", "--porcelain"])
        return status.isSuccess && status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Makes a checkout of the repository whose main clone is `mainClonePath` at `commit`, detached, in
    /// `destination`, which must not exist yet. The clone shares the main clone's objects through alternates
    /// (`clone --shared`), so a commit only a Worktree made is there too, and nothing is registered in the main
    /// clone: it is never a `git worktree`, which Orca ADE would see.
    public func makeFreshCheckout(mainClonePath: String, commit: String, destination: String) async throws {
        guard commit.count == 40 || commit.count == 64, commit.allSatisfy(\.isHexDigit) else {
            throw FreshCheckoutError(reason: "\"\(commit)\" is not a full commit name")
        }
        let clone = await git.run(["clone", "--quiet", "--shared", "--no-checkout", "--", mainClonePath, destination])
        guard clone.isSuccess else {
            throw FreshCheckoutError(reason: clone.failureReason(fallback: "git clone exited \(clone.exitCode)"))
        }
        let checkout = await git.run(["-C", destination, "checkout", "--quiet", "--detach", commit])
        guard checkout.isSuccess else {
            throw FreshCheckoutError(
                reason: checkout.failureReason(fallback: "git checkout exited \(checkout.exitCode)")
            )
        }
    }
}
