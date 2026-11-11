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
                command: Self.launchCommand(launcherURL: launcherURL)
            )
            self.terminal = term
        }

        /// The command typed into the tab's login shell: `bash <launcher>`, never `exec` (ADR-007 item 4).
        /// The path is shell-quoted, because Orca types the command into the shell as text, and a configuration
        /// directory with a space or a quote in it would otherwise split the path.
        public static func launchCommand(launcherURL: URL) -> String {
            "bash \(PassLauncher.shellQuote(launcherURL.path))"
        }

        /// Observes whether the terminal tab is gone before the host closes it (ADR-007 item 13).
        public func observeInterruptionEvidence() async -> TabInterruptionEvidence {
            guard let term = self.terminal else { return .init(tabState: .unavailable, loginState: .unknown) }
            let originalPID = term.processID
            var loginState = Self.loginState(for: originalPID)
            do {
                let state = try await workspace.terminal(term.handle)
                loginState = Self.loginState(for: state.processID ?? originalPID)
                if state.orphaned {
                    return .init(tabState: .orphaned, loginState: loginState)
                }
                return .init(tabState: .present, loginState: loginState)
            } catch {
                loginState = Self.loginState(for: originalPID)
                if case .terminalNotFound = error {
                    return .init(tabState: .missing, loginState: loginState)
                }
                return .init(tabState: .unavailable, loginState: loginState)
            }
        }

        private static func loginState(for pid: pid_t?) -> TabInterruptionEvidence.LoginState {
            guard let pid, pid > 0 else { return .unknown }
            let result = kill(pid, 0)
            if result == 0 || errno == EPERM { return .alive }
            return errno == ESRCH ? .dead : .unknown
        }

        public func observeTabGone() async -> Bool { (await observeInterruptionEvidence()).provesInterruption }

        /// Closes the terminal tab as a best effort, waiting for the tab's login process to exit.
        public func close() async {
            if let failure = await closeReportingFailure() {
                FileHandle.standardError.write(Data("failed to close terminal tab: \(failure)\n".utf8))
            }
        }

        /// The Probe retains a failed close as evidence and may retry it after fencing the CLI.
        public func closeReportingFailure() async -> String? {
            guard let term = self.terminal else { return nil }
            self.terminal = nil
            let workspace = self.workspace
            let bound = self.loginWaitBound
            let failure: String? = await Task {
                do { try await workspace.closeTerminal(term.handle) } catch { return "\(term.handle): \(error)" }
                if let pid = term.processID {
                    let deadline = ContinuousClock.now + bound
                    while kill(pid, 0) == 0 && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
                return nil
            }.value
            if failure != nil { self.terminal = term }
            return failure
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
