import Domain

/// Worktree-only fixtures fail explicitly if engine code starts requesting terminals.
extension Workspace {
    func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal {
        throw .unavailable("terminal creation is not supported by this test fixture")
    }

    func showTerminal(handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState? {
        throw .unavailable("terminal lookup is not supported by this test fixture")
    }

    func closeTerminal(handle: TerminalHandle) async throws(WorkspaceError) {
        throw .unavailable("terminal closure is not supported by this test fixture")
    }
}
