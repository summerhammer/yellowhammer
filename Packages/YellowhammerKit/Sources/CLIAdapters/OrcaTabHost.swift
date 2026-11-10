import Darwin
import Domain
import Foundation

/// Host for running Work Card passes in titled Orca terminal tabs (ADR-007 items 3, 4, 8, 10).
public final class OrcaTabHost: Sendable {
    public let workspace: any Workspace
    public let loginWaitBound: Duration

    public init(
        workspace: any Workspace,
        loginWaitBound: Duration = .seconds(3)
    ) {
        self.workspace = workspace
        self.loginWaitBound = loginWaitBound
    }

    /// One tab pass session managing the created terminal tab lifecycle.
    public actor TabSession {
        private let workspace: any Workspace
        private let worktreeID: WorktreeID
        private let sessionName: String
        private let loginWaitBound: Duration
        private var terminal: WorkspaceTerminal?

        public init(
            workspace: any Workspace,
            worktreeID: WorktreeID,
            sessionName: String,
            loginWaitBound: Duration = .seconds(3)
        ) {
            self.workspace = workspace
            self.worktreeID = worktreeID
            self.sessionName = sessionName
            self.loginWaitBound = loginWaitBound
        }

        /// The launcher starter closure handed to `CLIRunner` / `AgentCLIProcess.executeWrapped`.
        public func startLauncher(launcherURL: URL) async throws {
            let term = try await workspace.createTerminal(
                worktreeID: worktreeID,
                title: sessionName,
                command: "bash \(launcherURL.path)"
            )
            self.terminal = term
        }

        /// Observes whether the terminal tab is gone before the host closes it (ADR-007 item 13).
        public func observeTabGone() async -> Bool {
            guard let term = self.terminal else { return false }
            if let pid = term.processID, kill(pid, 0) != 0 {
                return true
            }
            do {
                let state = try await workspace.terminal(term.handle)
                if state.orphaned {
                    return true
                }
                if let pid = state.processID ?? term.processID, kill(pid, 0) != 0 {
                    return true
                }
                return false
            } catch {
                if case .terminalNotFound = error {
                    return true
                }
                if let pid = term.processID, kill(pid, 0) != 0 {
                    return true
                }
                return false
            }
        }

        /// Closes the terminal tab as a best effort, waiting for the tab's login process to exit.
        public func close() async {
            guard let term = self.terminal else { return }
            self.terminal = nil

            let workspace = self.workspace
            let bound = self.loginWaitBound
            await Task {
                do {
                    try await workspace.closeTerminal(term.handle)
                } catch {
                    FileHandle.standardError.write(
                        Data("failed to close terminal tab \(term.handle): \(error)\n".utf8)
                    )
                }
                if let pid = term.processID {
                    let deadline = ContinuousClock.now + bound
                    while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            }.value
        }
    }

    /// Creates a fresh session for one pass. Each pass gets a new tab; a tab is never reused.
    public func session(worktreeID: String, sessionName: String) -> TabSession {
        TabSession(
            workspace: workspace,
            worktreeID: WorktreeID(rawValue: worktreeID),
            sessionName: sessionName,
            loginWaitBound: loginWaitBound
        )
    }
}
