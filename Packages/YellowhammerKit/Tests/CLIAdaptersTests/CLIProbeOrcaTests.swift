@testable import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("CLIProbe Orca diagnostics")
struct CLIProbeOrcaTests {
    @Test("Claude's marker must come from a user message")
    func claudeMarker() {
        let metadata = Data(#"{"type":"custom-title","entrypoint":"sdk-cli"}"#.utf8)
        #expect(ClaudeCodeAdapter.probeEntrypoint(in: metadata).finding == .notRun)
        let user = Data(#"{"type":"user","entrypoint":"sdk-cli","uuid":"a"}"#.utf8)
        #expect(ClaudeCodeAdapter.probeEntrypoint(in: user).finding == .passed)
        let interactive = Data(#"{"type":"user","entrypoint":"cli","uuid":"a"}"#.utf8)
        #expect(ClaudeCodeAdapter.probeEntrypoint(in: interactive).finding == .failed)
    }

    @Test("Codex origin is observed only for this session and cwd; no resume check is enabled")
    func codexMarker() {
        let data = Data(#"{"type":"session_meta","payload":{"id":"s","cwd":"/probe","source":"exec"}}"#.utf8)
        #expect(CodexAdapter.probeSource(in: data, sessionID: "s", cwd: "/probe").finding == .passed)
        #expect(CodexAdapter.probeSource(in: data, sessionID: "other", cwd: "/probe").finding == .notRun)
        #expect(CodexAdapter.probeSource(in: data, sessionID: "s", cwd: "/other").finding == .notRun)
        let dispatch = CLIDispatch(
            route: Route(cli: "codex", model: "m", effort: "low")!, pass: .worker, instruction: "",
            worktreePath: "/probe", runDirectory: URL(filePath: "/probe/run"), timeout: .seconds(1),
            resume: CLISession(rawValue: "s"), executable: "/bin/false"
        )
        #expect(CodexAdapter().foreignTurns(before: dispatch) == .unsupported)
        let antigravity = AntigravityAdapter().probeForeignTurnMarker(of: .init(rawValue: "s"), dispatch: dispatch)
        #expect(antigravity.finding == .notRun)
    }

    @Test("A failed Orca allocation unregisters only the Probe repository")
    func allocationCleanup() async {
        let workspace = FailingProbeWorkspace()
        let probe = CLIProbe(protectedDirectories: [], workspace: workspace, wrapperExecutable: "/bin/false")
        let context = ProbeDispatchContext(
            route: Route(cli: "stub", model: "m", effort: "low")!, executable: "/bin/false", environment: [:],
            worktree: URL(filePath: "/probe"), runsDirectory: URL(filePath: "/probe/runs"), protectedDirectories: []
        )
        let result = await probe.runOrcaProbe(
            adapter: StubProbeAdapter(), context: context, dispatchA: .failure(CancellationError()),
            nonce: "nonce", directSessionName: "expected"
        )
        #expect(result.tabRecognition.finding == .notRun)
        #expect(await workspace.unregistered == [RegistrationID(rawValue: "probe-registration")])
        #expect(await workspace.registered == ["/probe"])
    }

    @Test("A tab whose wrapper never starts is still closed and its own Worktree released")
    func missingWrapperCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = FailingProbeWorkspace(worktreePath: root.path)
        let probe = CLIProbe(
            holdObservationTimeout: .milliseconds(20), pollInterval: .milliseconds(10), gracePeriod: .zero,
            protectedDirectories: [], workspace: workspace, wrapperExecutable: "/bin/false"
        )
        let context = ProbeDispatchContext(
            route: Route(cli: "stub", model: "m", effort: "low")!, executable: "/bin/false", environment: [:],
            worktree: root, runsDirectory: root.appendingPathComponent("runs"), protectedDirectories: []
        )
        let result = await probe.runOrcaProbe(
            adapter: StubProbeAdapter(), context: context, dispatchA: .failure(CancellationError()),
            nonce: "nonce", directSessionName: "expected"
        )
        #expect(result.tabCloseContainment.finding == .notRun)
        #expect(await workspace.closed == [TerminalHandle(rawValue: "own-tab")])
        #expect(await workspace.removed == [WorktreeID(rawValue: "own-worktree")])
        #expect(await workspace.unregistered == [RegistrationID(rawValue: "probe-registration")])
    }
}

private actor FailingProbeWorkspace: Workspace {
    let worktreePath: String?
    var registered: [String] = []
    var unregistered: [RegistrationID] = []
    var closed: [TerminalHandle] = []
    var removed: [WorktreeID] = []
    init(worktreePath: String? = nil) { self.worktreePath = worktreePath }
    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) -> RegistrationID {
        registered.append(path)
        return .init(rawValue: "probe-registration")
    }
    func unregisterRepository(id: RegistrationID) async throws(WorkspaceError) { unregistered.append(id) }
    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        guard let worktreePath else { throw .unavailable("fixture") }
        return .init(id: .init(rawValue: "own-worktree"), path: worktreePath, branch: name, displayName: name)
    }
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }
    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) { removed.append(id) }
    func createTerminal(
        worktreeID: WorktreeID, title: String, command: String
    ) async throws(WorkspaceError) -> WorkspaceTerminal { .init(handle: .init(rawValue: "own-tab")) }
    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        throw .terminalNotFound(handle)
    }
    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) { closed.append(handle) }
}
