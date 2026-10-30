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
    /// HEAD could not be read, or the pin could not be written; the reason says why.
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
            return .unreadable(reason: Self.reason(of: resolved, fallback: "HEAD of \(worktreePath) does not resolve"))
        }
        if head == recordedCommit { return .atRecordedCommit }

        let ancestry = await git.run(["-C", worktreePath, "merge-base", "--is-ancestor", recordedCommit, head])
        switch ancestry.exitCode {
        case 0:
            let count = await git.run(["-C", worktreePath, "rev-list", "--count", "\(recordedCommit)..\(head)"])
            guard count.isSuccess, let commits = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            else {
                return .unreadable(reason: Self.reason(of: count, fallback: "git rev-list exited \(count.exitCode)"))
            }
            return .after(commits: commits, head: head)
        case 1:
            return .differs(head: head)
        default:
            return .unreadable(
                reason: Self.reason(of: ancestry, fallback: "git merge-base exited \(ancestry.exitCode)")
            )
        }
    }

    /// Pins the HEAD of the Worktree at `worktreePath` at ``ref(for:)`` when it is not `recordedCommit`, whether
    /// or not it descends from it. Never pushes. A HEAD at `recordedCommit` writes nothing.
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
        let written = await git.run(["-C", worktreePath, "update-ref", ref, head])
        guard written.isSuccess else {
            return .failed(reason: Self.reason(of: written, fallback: "git update-ref exited \(written.exitCode)"))
        }
        return .pinned(ref: ref, relation: relation)
    }

    private static func reason(of result: GitCommandResult, fallback: String) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return stderr.isEmpty ? fallback : stderr
    }
}
