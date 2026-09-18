import Domain

/// What the engine-run Check yielded for one repository's Worktree.
public enum RepositoryCheckResult: Equatable, Sendable {
    /// The command exited 0; `output` is what it printed, kept for the Journal.
    case passed(output: String)
    /// The Check ran and did not pass; `output` is what it printed, for the Round that records it, and
    /// `exitStatus` is the shell's (128 plus the signal number when the command died by a signal).
    case failed(output: String, exitStatus: Int32)
    /// The repository declared `check = "none"`: a green comes from a model alone.
    case declaredNone
}

/// The Check seam the Card run calls after the worker and before the reviewer. The Check itself is a
/// command the engine runs in the Worktree (``WorktreeCheck``). An implementation that cannot run one must
/// throw rather than report a pass it did not earn.
public protocol RepositoryCheckRunning: Sendable {
    func run(repository: String, check: Check, worktreePath: String) async throws -> RepositoryCheckResult
}
