import Domain

/// What the engine-run Check yielded for one repository's Worktree (roadmap P8.5 runs it for real).
public enum RepositoryCheckResult: Equatable, Sendable {
    case passed
    /// The Check ran and did not pass; `output` is what it printed, for the Round that records it.
    case failed(output: String)
    /// The repository declared `check = "none"`: a green comes from a model alone.
    case declaredNone
}

/// The Check seam the Card run calls after the worker and before the reviewer. The Check itself — a
/// command the engine runs in the Worktree — is roadmap P8.5; until it lands, an implementation that
/// cannot run one must throw rather than report a pass it did not earn.
public protocol RepositoryCheckRunning: Sendable {
    func run(repository: String, check: Check, worktreePath: String) async throws -> RepositoryCheckResult
}
