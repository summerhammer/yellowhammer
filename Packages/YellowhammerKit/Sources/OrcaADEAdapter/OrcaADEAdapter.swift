import Domain
import Foundation

/// The Orca ADE implementation of the Workspace Port (ADR-001).
///
/// It shells out to the `orca` CLI, builds exactly the argument lists Orca ADE 1.4.203 expects for
/// worktrees and Orca ADE 1.4.253 expects for terminal operations, decodes its JSON envelope, and
/// translates every failure onto ``WorkspaceError``. It translates and never decides: a name collision
/// is returned to the caller as Orca ADE reported it, not judged here.
public struct OrcaADEAdapter: Workspace {
    let runner: any OrcaCommandRunner

    public init(runner: any OrcaCommandRunner = ProcessOrcaCommandRunner()) {
        self.runner = runner
    }

    public func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] {
        let payload: OrcaRepositoriesPayload = try await perform(["repo", "list", "--json"])
        return payload.repos.map(\.path)
    }

    @discardableResult
    public func registerRepository(path: String) async throws(WorkspaceError) -> RegistrationID {
        let payload: OrcaRepositoryResultPayload = try await perform(
            ["repo", "add", "--path", path, "--json"], repositoryPath: path
        )
        guard !payload.repo.path.isEmpty else {
            throw .malformedResponse("orca repo add returned an empty Repo path")
        }
        let id = payload.repo.id ?? payload.repo.path
        guard !id.isEmpty else {
            throw .malformedResponse("orca repo add returned an empty Repo id")
        }
        return RegistrationID(rawValue: id)
    }

    public func unregisterRepository(id: RegistrationID) async throws(WorkspaceError) {
        let arguments = ["project", "setup-delete", "--setup", id.rawValue, "--force", "--json"]
        let _: OrcaSetupDeleteResultPayload = try await perform(arguments)
    }

    public func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        var arguments = ["worktree", "create", "--repo", "path:\(repositoryPath)", "--name", name, "--no-parent"]
        if let baseBranch {
            arguments += ["--base-branch", baseBranch]
        }
        arguments.append("--json")

        let payload: OrcaCreateResultPayload = try await perform(arguments, repositoryPath: repositoryPath)
        guard let worktree = payload.worktree else {
            throw .malformedResponse("orca worktree create's result carried no worktree")
        }
        return Self.workspaceWorktree(worktree)
    }

    public func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] {
        let arguments = ["worktree", "list", "--repo", "path:\(repositoryPath)", "--json"]
        let payload: OrcaListResultPayload = try await perform(arguments, repositoryPath: repositoryPath)
        return (payload.worktrees ?? [])
            .filter { !($0.isMainWorktree ?? false) }
            .map(Self.workspaceWorktree)
    }

    public func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        var arguments = ["worktree", "rm", "--worktree", "id:\(id.rawValue)"]
        if force {
            arguments.append("--force")
        }
        arguments.append("--json")

        let _: OrcaRemoveResultPayload = try await perform(arguments, worktreeIDForNotFound: id)
    }

    public func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal {
        let arguments = [
            "terminal", "create",
            "--worktree", "id:\(worktreeID.rawValue)",
            "--title", title,
            "--command", command,
            "--json"
        ]
        let payload: OrcaTerminalCreateResultPayload = try await perform(
            arguments,
            worktreeIDForNotFound: worktreeID
        )
        guard let handle = payload.resolvedHandle else {
            throw .malformedResponse("orca terminal create's result carried no handle")
        }
        return WorkspaceTerminal(
            handle: TerminalHandle(rawValue: handle),
            processID: try Self.sessionLeaderPID(payload.resolvedProcessID, operation: "create")
        )
    }

    public func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        let arguments = ["terminal", "show", "--terminal", handle.rawValue, "--json"]
        let payload: OrcaTerminalShowResultPayload
        do {
            payload = try await perform(arguments, terminalHandleForNotFound: handle)
        } catch .refused(let code, _) where Self.unknownTerminalCodes.contains(code) {
            throw .terminalNotFound(handle)
        }
        return WorkspaceTerminalState(
            orphaned: payload.resolvedOrphaned,
            processID: try Self.sessionLeaderPID(payload.resolvedProcessID, operation: "show")
        )
    }

    public func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {
        let arguments = ["terminal", "close", "--terminal", handle.rawValue, "--tab", "--json"]
        let _: OrcaTerminalCloseResultPayload = try await perform(
            arguments,
            terminalHandleForNotFound: handle
        )
    }

    /// The codes Orca ADE 1.4.253 returns from `terminal show` for a handle it no longer knows.
    /// Only `show` reads them as gone: from `create` or `close` they stay vendor refusals.
    private static let unknownTerminalCodes: Set<String> = ["terminal_handle_stale", "terminal_not_found"]

    /// A reported session-leader pid must be positive: it is later probed with `kill(pid, 0)`, where
    /// 0 names the caller's own process group and -1 every process the caller may signal.
    private static func sessionLeaderPID(
        _ pid: pid_t?, operation: String
    ) throws(WorkspaceError) -> pid_t? {
        guard let pid else { return nil }
        guard pid > 0 else {
            throw .malformedResponse("orca terminal \(operation) returned an invalid session-leader pid \(pid)")
        }
        return pid
    }

    private static func workspaceWorktree(_ payload: OrcaWorktreePayload) -> WorkspaceWorktree {
        WorkspaceWorktree(
            id: WorktreeID(rawValue: payload.id),
            path: payload.path,
            branch: Self.stripRefsHeadsPrefix(payload.branch),
            displayName: payload.displayName
        )
    }

    private static func stripRefsHeadsPrefix(_ branch: String) -> String {
        let prefix = "refs/heads/"
        return branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
    }

    /// Maps a failed envelope's vendor error onto ``WorkspaceError``.
    private static func translate(
        _ failure: OrcaErrorPayload,
        repositoryPath: String?,
        worktreeIDForNotFound: WorktreeID?,
        terminalHandleForNotFound: TerminalHandle?
    ) -> WorkspaceError {
        switch failure.code {
        case "runtime_unavailable":
            return .unavailable(failure.message)
        case "repo_not_found":
            return .repositoryNotRegistered(path: repositoryPath ?? "")
        case "selector_not_found":
            if let worktreeIDForNotFound {
                return .worktreeNotFound(worktreeIDForNotFound)
            }
            if let terminalHandleForNotFound {
                return .terminalNotFound(terminalHandleForNotFound)
            }
        default:
            break
        }
        return .refused(code: failure.code, message: failure.message)
    }

    /// Runs one `orca` command, decodes its envelope for `Result`, and maps failure onto
    /// ``WorkspaceError``. `repositoryPath` names the repository for a `repo_not_found` refusal;
    /// `worktreeIDForNotFound` names the Worktree for a `selector_not_found` refusal;
    /// `terminalHandleForNotFound` names the terminal handle for a `selector_not_found` refusal.
    private func perform<Result: Decodable>(
        _ arguments: [String],
        repositoryPath: String? = nil,
        worktreeIDForNotFound: WorktreeID? = nil,
        terminalHandleForNotFound: TerminalHandle? = nil
    ) async throws(WorkspaceError) -> Result {
        let output: OrcaCommandOutput
        do {
            output = try await runner.run(arguments)
        } catch {
            throw .unavailable("the orca executable could not be launched: \(error)")
        }

        guard let data = output.stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(OrcaEnvelope<Result>.self, from: data) else {
            if output.exitCode != 0 {
                let detail = output.stderr.isEmpty ? output.stdout : output.stderr
                throw .unavailable("orca exited \(output.exitCode): \(detail)")
            }
            throw .malformedResponse("orca's output was not the expected JSON envelope: \(output.stdout)")
        }

        guard envelope.ok else {
            throw Self.translate(
                envelope.error ?? OrcaErrorPayload(code: "unknown", message: "orca reported failure"),
                repositoryPath: repositoryPath,
                worktreeIDForNotFound: worktreeIDForNotFound,
                terminalHandleForNotFound: terminalHandleForNotFound
            )
        }

        guard output.exitCode == 0 else {
            throw .unavailable("orca exited \(output.exitCode) despite reporting success: \(output.stderr)")
        }

        guard let result = envelope.result else {
            throw .malformedResponse("orca's response carried no result")
        }
        return result
    }
}
