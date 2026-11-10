import Config
import Darwin
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Repositories
import Synchronization
import Testing

// MARK: - Fake Workspace

final class FakeTabWorkspace: Workspace, @unchecked Sendable {
    struct CreateCall: Sendable, Equatable {
        let worktreeID: WorktreeID
        let title: String
        let command: String
    }

    struct TerminalInfo: Sendable {
        let handle: TerminalHandle
        let processID: pid_t
    }

    private struct State {
        var createCalls: [CreateCall] = []
        var closedHandles: [TerminalHandle] = []
        var terminals: [TerminalHandle: TerminalInfo] = [:]
        var nextID = 1
        var scriptedCreateError: WorkspaceError?
    }

    private let state: Mutex<State>

    init(scriptedCreateError: WorkspaceError? = nil) {
        state = Mutex(State(scriptedCreateError: scriptedCreateError))
    }

    var createCalls: [CreateCall] { state.withLock { $0.createCalls } }
    var closedHandles: [TerminalHandle] { state.withLock { $0.closedHandles } }
    var terminals: [TerminalHandle: TerminalInfo] { state.withLock { $0.terminals } }

    func scriptCreateError(_ error: WorkspaceError?) {
        state.withLock { $0.scriptedCreateError = error }
    }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) {}
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
        let error = state.withLock { $0.scriptedCreateError }
        if let error {
            throw error
        }

        let pid = try spawnCommandInFreshSession(command: command)
        let handle = state.withLock { lockedState -> TerminalHandle in
            let id = lockedState.nextID
            lockedState.nextID += 1
            let newHandle = TerminalHandle(rawValue: "tab-\(id)")
            lockedState.createCalls.append(CreateCall(worktreeID: worktreeID, title: title, command: command))
            lockedState.terminals[newHandle] = TerminalInfo(handle: newHandle, processID: pid)
            return newHandle
        }
        return WorkspaceTerminal(handle: handle, processID: pid)
    }

    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        throw .unavailable("test fake")
    }

    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {
        let term = state.withLock { lockedState -> TerminalInfo? in
            lockedState.closedHandles.append(handle)
            return lockedState.terminals[handle]
        }
        guard let term else { return }
        kill(term.processID, SIGKILL)
        waitpid(term.processID, nil, 0)
    }

    private func spawnCommandInFreshSession(command: String) throws(WorkspaceError) -> pid_t {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let executable = "/bin/bash"
        let argv = [strdup(executable), strdup("-c"), strdup(command), nil]
        defer {
            for ptr in argv where ptr != nil { free(ptr) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, nil, &attr, argv, nil)
        guard rc == 0 else {
            throw .unavailable("failed to spawn bash: \(rc)")
        }
        return pid
    }
}

// MARK: - Test Fixture

private final class OrcaTabPassFixture {
    let tempDir: URL
    let worktreeDir: URL
    let runsDir: URL
    let scriptPath: URL
    let sleepScriptPath: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("orca-tab-pass-tests-\(UUID().uuidString)")
        self.tempDir = base
        self.worktreeDir = base.appendingPathComponent("worktree")
        self.runsDir = base.appendingPathComponent("runs")
        self.scriptPath = base.appendingPathComponent("fake-claude.sh")
        self.sleepScriptPath = base.appendingPathComponent("fake-claude-sleep.sh")

        try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let scriptContent = """
        #!/bin/sh
        printf '{"type":"result","structured_output":{"schema":"yellowhammer.result.worker",\
        "version":1,"outcome":"completed","commit":"0123456789abcdef0123456789abcdef01234567",\
        "summary":"tab pass done"},"session_id":"sess-tab-1"}\\n'
        exit 0
        """
        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        chmod(scriptPath.path, 0o755)

        let sleepContent = """
        #!/bin/sh
        sleep 30
        exit 0
        """
        try sleepContent.write(to: sleepScriptPath, atomically: true, encoding: .utf8)
        chmod(sleepScriptPath.path, 0o755)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func passWrapperChildURL() throws -> URL {
        let bundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
            ?? Bundle(for: FakeTabWorkspace.self)
        let dir = bundle.bundleURL.deletingLastPathComponent()
        let executable = dir.appending(component: "PassWrapperChild")
        try #require(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "PassWrapperChild is not built at \(executable.path)"
        )
        return executable
    }

    func makeDispatch(
        workspace: (any Workspace)? = nil,
        scriptURL: URL? = nil,
        timeout: Duration = .seconds(10)
    ) throws -> CLIAdapterDispatch {
        let wrapperURL = try passWrapperChildURL()
        let targetScript = scriptURL ?? scriptPath
        return CLIAdapterDispatch(
            runsDirectory: runsDir,
            timeout: timeout,
            declaredExecutables: ["claude": targetScript.path],
            path: "/usr/bin:/bin",
            environment: ["HOME": tempDir.path],
            fileExists: { _ in true },
            workspace: workspace,
            wrapperExecutable: wrapperURL.path
        )
    }

    func makeRequest(
        pass: RunPass = .worker,
        worktreeID: String? = "wt-1",
        sessionName: String? = "tab-session-test",
        resumeSession: String? = nil
    ) -> AgentDispatchRequest {
        let repo = Repo(name: "repo", path: worktreeDir.path, role: .backend)
        let card = InstructionCard(key: "BACK-1", title: "Test Card")
        let brief = ArchitecturalBrief(prose: "brief", transcriptions: [])
        let instruction = Instruction(
            pass: pass,
            card: card,
            brief: brief,
            definitionOfDone: [],
            repository: InstructionRepository(
                repo: repo,
                worktreePath: worktreeDir.path,
                featureBranch: "feat",
                check: .none
            ),
            route: Route(cli: "claude", model: "opus", effort: "high")!,
            payloads: .none
        )
        return AgentDispatchRequest(
            runID: RunID(rawValue: "run-1")!,
            issueID: "BACK-1",
            attemptID: 1,
            route: Route(cli: "claude", model: "opus", effort: "high")!,
            pass: pass,
            instruction: .card(instruction),
            worktreePath: worktreeDir.path,
            resumeSession: resumeSession,
            sessionName: sessionName,
            worktreeID: worktreeID
        )
    }
}

extension RunOutcome {
    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

// MARK: - Suite

@Suite("Orca Terminal Tab Passes", .timeLimit(.minutes(1)))
struct OrcaTabPassTests {
    @Test("Worker pass runs in tab titled with session name, and a second Round gets a second tab (c1)")
    func workerPassRunsInTabAndSecondRoundGetsSecondTab() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(workspace: workspace)

        let req1 = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-42", sessionName: "round-1-session"
        )
        let report1 = try await dispatch.dispatch(req1)

        #expect(report1.outcome.isCompleted)
        #expect(report1.session == "sess-tab-1")
        #expect(report1.notShownInOrca == nil)

        #expect(workspace.createCalls.count == 1)
        let call1 = try #require(workspace.createCalls.first)
        #expect(call1.worktreeID == WorktreeID(rawValue: "wt-42"))
        #expect(call1.title == "round-1-session")
        #expect(call1.command.hasPrefix("bash "))
        #expect(workspace.closedHandles.count == 1)

        let req2 = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-42", sessionName: "round-2-session",
            resumeSession: "sess-tab-1"
        )
        let report2 = try await dispatch.dispatch(req2)

        #expect(report2.outcome.isCompleted)
        #expect(workspace.createCalls.count == 2)
        let call2 = workspace.createCalls[1]
        #expect(call2.worktreeID == WorktreeID(rawValue: "wt-42"))
        #expect(call2.title == "round-2-session")
        #expect(workspace.closedHandles.count == 2)
        #expect(workspace.closedHandles[0] != workspace.closedHandles[1])
    }

    @Test("Tab is closed after pass, login is gone, and attributed fence reports nothing from it (c3)")
    func tabIsClosedAndAttributedFenceReportsNothingFromTab() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(workspace: workspace)

        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-99", sessionName: "fence-test-session"
        )
        let report = try await dispatch.dispatch(req)

        #expect(report.outcome.isCompleted)
        let handle = try #require(workspace.closedHandles.first)
        let term = try #require(workspace.terminals[handle])

        #expect(kill(term.processID, 0) != 0)

        let snapshot = try #require(report.snapshot)
        let fencer = ProcessFencer(quiescenceTimeout: .seconds(2))
        let fenceOutcome = await fencer.fence(
            worktreePath: fixture.worktreeDir.path, attributedTo: snapshot
        )

        guard case .quiescent(let killed, let unattributed) = fenceOutcome else {
            Issue.record("Expected quiescent fence outcome, got \(fenceOutcome)")
            return
        }
        #expect(killed.isEmpty)
        #expect(unattributed.isEmpty)
    }

    @Test("WorkspaceError.unavailable falls back to direct spawn, launcher invalidated, notShownInOrca set (c4)")
    func unavailableFallsBackToDirectSpawn() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace(
            scriptedCreateError: .unavailable("Orca daemon not running")
        )
        let dispatch = try fixture.makeDispatch(workspace: workspace)

        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-fallback", sessionName: "fallback-session"
        )
        let report = try await dispatch.dispatch(req)

        #expect(report.outcome.isCompleted)
        #expect(report.notShownInOrca == "Orca daemon not running")
        #expect(workspace.closedHandles.isEmpty)

        let runDir = CLIAdapterDispatch.runDirectory(
            runsDirectory: fixture.runsDir, runID: req.runID, issueID: req.issueID,
            attemptID: req.attemptID, pass: req.pass
        )
        let launcherURL = runDir.appendingPathComponent("launcher.sh")
        #expect(!FileManager.default.fileExists(atPath: launcherURL.path))
    }

    @Test("Other WorkspaceError ends pass Crashed-Unknown without excluding Route (c5)")
    func otherWorkspaceErrorEndsCrashedUnknown() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace(
            scriptedCreateError: .refused(code: "tab_limit", message: "maximum terminal tabs reached")
        )
        let dispatch = try fixture.makeDispatch(workspace: workspace)

        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-refused", sessionName: "refused-session"
        )
        let report = try await dispatch.dispatch(req)

        guard case .crashedUnknown(let reason) = report.outcome else {
            Issue.record("Expected .crashedUnknown outcome, got \(report.outcome)")
            return
        }
        guard case .engineStopped(let cause) = reason else {
            Issue.record("Expected .engineStopped cause, got \(reason)")
            return
        }
        #expect(cause.contains("tab_limit"))
        #expect(report.session == nil)

        let runDir = CLIAdapterDispatch.runDirectory(
            runsDirectory: fixture.runsDir, runID: req.runID, issueID: req.issueID,
            attemptID: req.attemptID, pass: req.pass
        )
        let launcherURL = runDir.appendingPathComponent("launcher.sh")
        #expect(!FileManager.default.fileExists(atPath: launcherURL.path))
    }

    @Test("Verifier pass and authoring passes never touch the Workspace (c2)")
    func verifierAndAuthoringPassesNeverTouchWorkspace() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(workspace: workspace)

        let verifierReq = fixture.makeRequest(pass: .verifier, worktreeID: "wt-1")
        _ = try? await dispatch.dispatch(verifierReq)
        #expect(workspace.createCalls.isEmpty)

        let selectionReq = fixture.makeRequest(pass: .selection, worktreeID: "wt-1")
        _ = try? await dispatch.dispatch(selectionReq)
        #expect(workspace.createCalls.isEmpty)

        let breakdownReq = fixture.makeRequest(pass: .breakdown, worktreeID: "wt-1")
        _ = try? await dispatch.dispatch(breakdownReq)
        #expect(workspace.createCalls.isEmpty)

        let noWorktreeReq = fixture.makeRequest(pass: .worker, worktreeID: nil)
        _ = try? await dispatch.dispatch(noWorktreeReq)
        #expect(workspace.createCalls.isEmpty)
    }

    @Test("Best-effort tab close occurs even when the dispatch Task is cancelled (c3)")
    func tabCloseIsBestEffortWhenTaskCancelled() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.sleepScriptPath, timeout: .seconds(30)
        )

        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-cancel", sessionName: "cancel-session"
        )

        let task = Task {
            try await dispatch.dispatch(req)
        }

        while workspace.createCalls.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }

        task.cancel()
        _ = try? await task.value

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while workspace.closedHandles.isEmpty && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(workspace.closedHandles.count == 1)
        let handle = try #require(workspace.closedHandles.first)
        let term = try #require(workspace.terminals[handle])
        #expect(kill(term.processID, 0) != 0)
    }
}
