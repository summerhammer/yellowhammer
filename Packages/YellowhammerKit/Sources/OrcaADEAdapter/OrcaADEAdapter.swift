import Domain
import Foundation

/// The Orca ADE implementation of the Workspace Port (ADR-001).
///
/// It shells out to the `orca` CLI, builds exactly the argument lists Orca ADE 1.4.203 expects,
/// decodes its JSON envelope, and translates every failure onto ``WorkspaceError``. It translates and
/// never decides: a name collision is returned to the caller as Orca ADE reported it, not judged here.
public struct OrcaADEAdapter: Workspace {
    let runner: any OrcaCommandRunner

    public init(runner: any OrcaCommandRunner = ProcessOrcaCommandRunner()) {
        self.runner = runner
    }

    public func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] {
        let payload: OrcaRepositoriesPayload = try await perform(["repo", "list", "--json"])
        return payload.repos.map(\.path)
    }

    public func registerRepository(path: String) async throws(WorkspaceError) {
        let payload: OrcaRepositoryResultPayload = try await perform(
            ["repo", "add", "--path", path, "--json"], repositoryPath: path
        )
        guard !payload.repo.path.isEmpty else {
            throw .malformedResponse("orca repo add returned an empty Repo path")
        }
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

    /// Runs one `orca` command, decodes its envelope for `Result`, and maps failure onto
    /// ``WorkspaceError``. `repositoryPath` names the repository for a `repo_not_found` refusal;
    /// `worktreeIDForNotFound` names the Worktree for a `selector_not_found` refusal.
    private func perform<Result: Decodable>(
        _ arguments: [String],
        repositoryPath: String? = nil,
        worktreeIDForNotFound: WorktreeID? = nil
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
            let failure = envelope.error ?? OrcaErrorPayload(code: "unknown", message: "orca reported failure")
            if failure.code == "repo_not_found" {
                throw .repositoryNotRegistered(path: repositoryPath ?? "")
            }
            if failure.code == "selector_not_found", let worktreeIDForNotFound {
                throw .worktreeNotFound(worktreeIDForNotFound)
            }
            throw .refused(code: failure.code, message: failure.message)
        }

        guard let result = envelope.result else {
            throw .malformedResponse("orca's response carried no result")
        }
        return result
    }
}
