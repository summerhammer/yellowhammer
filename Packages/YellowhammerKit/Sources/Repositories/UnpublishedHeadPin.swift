import Domain
import Foundation

/// How a held Worktree's HEAD stands against its recorded commit: the Pushed Tip, or the recorded base commit for
/// a repository with the No-Pushed-Branch Outcome (OQ191 items 6 and 9).
public enum WorktreeHeadRelation: Equatable, Sendable {
    /// HEAD is the recorded commit.
    case atRecordedCommit
    /// HEAD descends from the recorded commit, `commits` commits after it.
    case after(commits: Int, head: String)
    /// HEAD does not descend from the recorded commit: a rewritten branch.
    case differs(head: String)
    /// git could not read HEAD or compare it with the recorded commit; the reason says why.
    case unreadable(reason: String)
}

/// What pinning a held Worktree's HEAD before release did.
public enum UnpublishedHeadPinResult: Equatable, Sendable {
    /// HEAD was pinned at `ref`, a local ref outside `refs/heads/`. `relation` is never `.atRecordedCommit` or
    /// `.unreadable`.
    case pinned(ref: String, relation: WorktreeHeadRelation)
    /// HEAD is the recorded commit: nothing to pin.
    case notNeeded
    /// HEAD was already pinned at `ref` by an earlier firing: nothing was written this time.
    case alreadyPinned(ref: String)
    /// HEAD could not be read, or the pin could not be written; the reason says why.
    case failed(reason: String)
}

/// What pinning a Feature Branch in the main repository before release did.
public enum UnpublishedBranchPinResult: Equatable, Sendable {
    /// The branch was pinned at `ref`, a local ref outside `refs/heads/`.
    case pinned(ref: String, relation: WorktreeHeadRelation)
    /// The branch was already pinned at `ref` by an earlier firing: nothing was written this time.
    case alreadyPinned(ref: String)
    /// The branch is at the recorded commit: nothing to pin.
    case notNeeded
    /// The repository is readable and has no such branch.
    case absent
    /// The repository is missing or unreadable, or git failed; the reason says why.
    case failed(reason: String)
}

/// The local git behind the unpublished-commits pin (spec: landing/open-one-pull-request-per-repository,
/// `#unpublished-commits-pin`; OQ191 items 6 and 9): how a held Worktree's HEAD stands against its recorded
/// commit, and the pin that keeps a HEAD that is not the recorded commit — descendant or not — once the Worktree
/// is released.
///
/// The pin is `refs/yellowhammer/unpublished/<branch>`, outside `refs/heads/`, which Orca ADE does not delete when
/// it removes a Worktree (loop-state/reconcile-worktrees-at-act-start, `#ghost-worktree-purge`). A Worktree shares
/// the main clone's ref store, so the pin written from the Worktree is in the main clone. It is never pushed.
/// An existing pin advances only to a descendant, preserving the previously pinned commits.
/// Local git, not behind a Port.
public struct UnpublishedHeadPin: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The pin ref for `branch`. Branch names may carry an Orca ADE prefix containing `/`, so the ref is always
    /// fully qualified.
    public static func ref(for branch: FeatureBranch) -> String {
        "refs/yellowhammer/unpublished/\(branch.name)"
    }

    /// How the HEAD of the Worktree at `worktreePath` stands against `recordedCommit`.
    public func headRelation(worktreePath: String, recordedCommit: String) async -> WorktreeHeadRelation {
        let resolved = await git.run(["-C", worktreePath, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
        let head = resolved.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolved.isSuccess, !head.isEmpty else {
            return .unreadable(reason: resolved.failureReason(fallback: "HEAD of \(worktreePath) does not resolve"))
        }
        return await commitRelation(head: head, recordedCommit: recordedCommit, gitDirectory: worktreePath)
    }

    /// How the commit `head` in `gitDirectory` stands against `recordedCommit`.
    public func commitRelation(
        head: String, recordedCommit: String, gitDirectory: String
    ) async -> WorktreeHeadRelation {
        if head == recordedCommit { return .atRecordedCommit }

        let ancestry = await git.run(["-C", gitDirectory, "merge-base", "--is-ancestor", recordedCommit, head])
        switch ancestry.exitCode {
        case 0:
            let count = await git.run(["-C", gitDirectory, "rev-list", "--count", "\(recordedCommit)..\(head)"])
            guard count.isSuccess, let commits = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return .unreadable(reason: count.failureReason(fallback: "git rev-list exited \(count.exitCode)"))
            }
            return .after(commits: commits, head: head)
        case 1:
            return .differs(head: head)
        default:
            return .unreadable(
                reason: ancestry.failureReason(fallback: "git merge-base exited \(ancestry.exitCode)")
            )
        }
    }

    /// Pins the HEAD of the Worktree at `worktreePath` at ``ref(for:)`` when it is not `recordedCommit`, whether
    /// or not it descends from it. Never pushes. A HEAD at `recordedCommit` writes nothing, and nor does one the pin
    /// already points at.
    public func pinUnpublishedHead(
        worktreePath: String, recordedCommit: String, branch: FeatureBranch
    ) async -> UnpublishedHeadPinResult {
        let relation = await headRelation(worktreePath: worktreePath, recordedCommit: recordedCommit)
        let head: String
        switch relation {
        case .atRecordedCommit:
            return .notNeeded
        case .unreadable(let reason):
            return .failed(reason: reason)
        case .after(_, let moved), .differs(let moved):
            head = moved
        }
        let ref = Self.ref(for: branch)
        switch await writePin(ref: ref, commit: head, gitDirectory: worktreePath) {
        case .written:
            return .pinned(ref: ref, relation: relation)
        case .alreadyPinned:
            return .alreadyPinned(ref: ref)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }

    /// Pins `branch` in the main repository at `repositoryPath` at ``ref(for:)`` when it is not `recordedCommit`.
    /// Tells "the branch does not exist" apart from "git failed" by verifying `--git-dir` first through
    /// ``FeatureBranchRecoveryPin/tip(of:repositoryPath:)``.
    public func pinFeatureBranch(
        repositoryPath: String, recordedCommit: String, branch: FeatureBranch
    ) async -> UnpublishedBranchPinResult {
        let recoveryPin = FeatureBranchRecoveryPin(git: git)
        let tipLookup = await recoveryPin.tip(of: branch, repositoryPath: repositoryPath)
        let branchCommit: String
        switch tipLookup {
        case .absent:
            return .absent
        case .failed(let reason):
            return .failed(reason: reason)
        case .commit(let commit):
            branchCommit = commit
        }

        let relation = await commitRelation(
            head: branchCommit, recordedCommit: recordedCommit, gitDirectory: repositoryPath
        )
        switch relation {
        case .atRecordedCommit:
            return .notNeeded
        case .unreadable(let reason):
            return .failed(reason: reason)
        case .after, .differs:
            break
        }

        let ref = Self.ref(for: branch)
        switch await writePin(ref: ref, commit: branchCommit, gitDirectory: repositoryPath) {
        case .written:
            return .pinned(ref: ref, relation: relation)
        case .alreadyPinned:
            return .alreadyPinned(ref: ref)
        case .failed(let reason):
            return .failed(reason: reason)
        }
    }

    private enum PinWriteResult {
        case written
        case alreadyPinned
        case failed(reason: String)
    }

    /// A pin may advance only when the new commit preserves everything reachable from the old one.
    /// The old value also guards against a ref moving between the read and the write.
    private func writePin(ref: String, commit: String, gitDirectory: String) async -> PinWriteResult {
        let existing = await git.run([
            "-C", gitDirectory, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"
        ])
        let old = existing.isSuccess ? existing.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        if old == commit { return .alreadyPinned }
        if !old.isEmpty {
            let ancestry = await git.run(["-C", gitDirectory, "merge-base", "--is-ancestor", old, commit])
            switch ancestry.exitCode {
            case 0:
                break
            case 1:
                return .failed(reason: "already pinned at \(old), which is not an ancestor of \(commit)")
            default:
                return .failed(
                    reason: ancestry.failureReason(fallback: "git merge-base exited \(ancestry.exitCode)")
                )
            }
        }
        let written = await git.run(["-C", gitDirectory, "update-ref", ref, commit, old])
        guard written.isSuccess else {
            return .failed(reason: written.failureReason(fallback: "git update-ref exited \(written.exitCode)"))
        }
        return .written
    }
}
