import Domain
import Foundation

/// Pins the commit a Feature was authored against under `refs/yellowhammer/base/<worktree-name>`, in the
/// repository's MAIN clone, so a new Worktree can be cut at exactly that commit
/// (graph-execution/allocate-a-worktree-per-graph-and-repo, "Stacked Worktree allocation on
/// `effective_base(R)`"; feature-authoring/select-the-next-feature, `#effective-base`).
///
/// Orca ADE's `--base-branch` is documented to accept a local branch or a `refs/yellowhammer/...` ref
/// (feasibility probes, 2026-09-13), not a bare commit. A repository whose recorded base is mainline as it
/// was at selection has no ref that still names that commit once mainline moves, so the commit is pinned
/// and the pin is passed instead. (The live probe of whether Orca ADE also accepts a bare SHA was not run:
/// `orca repo` has no remove command, so a probe repository could not be unregistered afterwards.) The pin is
/// deleted best-effort once the Worktree exists; a leftover pin is harmless. Local git, not behind a Port.
public struct RecordedBasePin: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// The pin ref for the Worktree requested as `worktreeName`.
    public static func ref(for worktreeName: String) -> String {
        "refs/yellowhammer/base/\(worktreeName)"
    }

    /// Writes the pin at `commit`, moving it if one is left over from an earlier allocation.
    public func pin(commit: String, worktreeName: String, repositoryPath: String) async -> LandedPinResult {
        let result = await git.run(["-C", repositoryPath, "update-ref", Self.ref(for: worktreeName), commit])
        guard !result.isSuccess else { return .done }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(stderr.isEmpty ? "git update-ref exited \(result.exitCode)" : stderr)
    }

    /// Deletes the pin, best-effort: an absent pin is not a failure and nothing depends on the outcome.
    public func unpin(worktreeName: String, repositoryPath: String) async {
        _ = await git.run(["-C", repositoryPath, "update-ref", "-d", Self.ref(for: worktreeName)])
    }
}
