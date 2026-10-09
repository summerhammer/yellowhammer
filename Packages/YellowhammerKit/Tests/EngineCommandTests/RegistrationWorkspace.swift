import Domain
import Synchronization

/// Explicit registry seam: setup tests never invoke the real Orca ADE runtime.
final class RegistrationWorkspace: Workspace, Sendable {
    private struct State {
        var paths: Set<String>
        var additions: [String] = []
        var reads = 0
    }
    private let state: Mutex<State>
    let readFailure: WorkspaceError?
    let failures: [String: WorkspaceError]

    init(paths: Set<String> = [], readFailure: WorkspaceError? = nil, failures: [String: WorkspaceError] = [:]) {
        state = Mutex(State(paths: paths))
        self.readFailure = readFailure
        self.failures = failures
    }
    var additions: [String] { state.withLock { $0.additions } }
    var reads: Int { state.withLock { $0.reads } }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] {
        state.withLock { $0.reads += 1 }
        if let readFailure { throw readFailure }
        return state.withLock { Array($0.paths) }
    }
    func registerRepository(path: String) async throws(WorkspaceError) {
        state.withLock { $0.additions.append(path) }
        if let error = failures[path] { throw error }
        state.withLock { $0.paths.insert(path) }
    }
    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        throw .unavailable("registry-only test seam")
    }
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }
    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {}
}
