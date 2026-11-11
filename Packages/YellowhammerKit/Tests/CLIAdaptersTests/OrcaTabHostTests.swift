@testable import CLIAdapters
import Domain
import Foundation
import Synchronization
import Testing

/// Runs each terminal's command with `bash -c`, the way Orca types `--command` into the tab's login shell.
private final class ShellTypingWorkspace: Workspace, Sendable {
    private let commands = Mutex<[String]>([])

    var createdCommands: [String] { commands.withLock { $0 } }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) -> RegistrationID {
        RegistrationID(rawValue: path)
    }
    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        throw .unavailable("test fake")
    }
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }
    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {}

    func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal {
        commands.withLock { $0.append(command) }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/bash")
        shell.arguments = ["-c", command]
        do {
            try shell.run()
        } catch {
            throw .unavailable("could not start bash: \(error)")
        }
        shell.waitUntilExit()
        return WorkspaceTerminal(handle: TerminalHandle(rawValue: "tab-1"), processID: nil)
    }

    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        WorkspaceTerminalState(orphaned: false, processID: nil)
    }

    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {}
}

@Suite("Orca tab host")
struct OrcaTabHostTests {
    @Test("The tab runs a launcher whose path holds a space and a single quote")
    func tabRunsLauncherAtPathNeedingQuotes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh tab 'quoted' \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(component: "ran")
        let launcher = directory.appending(component: PassLauncher.fileName)
        try "touch \(PassLauncher.shellQuote(marker.path))\n".write(to: launcher, atomically: true, encoding: .utf8)

        let workspace = ShellTypingWorkspace()
        let session = OrcaTabHost(workspace: workspace).session(worktreeID: "wt-1", sessionName: "quoted")
        try await session.startLauncher(launcherURL: launcher)
        await session.close()

        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect(workspace.createdCommands == ["bash \(PassLauncher.shellQuote(launcher.path))"])
    }
}
