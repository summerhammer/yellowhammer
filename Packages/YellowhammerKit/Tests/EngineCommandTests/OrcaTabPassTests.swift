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
        let launcherProcessID: pid_t
    }

    private struct State {
        var createCalls: [CreateCall] = []
        var createAttempts = 0
        var closedHandles: [TerminalHandle] = []
        var terminals: [TerminalHandle: TerminalInfo] = [:]
        var terminalStates: [TerminalHandle: WorkspaceTerminalState] = [:]
        var terminalErrors: [TerminalHandle: WorkspaceError] = [:]
        var observedBeforeClose: [TerminalHandle: Bool] = [:]
        var defaultTerminalState: WorkspaceTerminalState?
        var scriptedProcessID: pid_t?
        var nextID = 1
        var scriptedCreateError: WorkspaceError?
        var scriptedCloseError: WorkspaceError?
    }

    private let state: Mutex<State>

    init(scriptedCreateError: WorkspaceError? = nil) {
        state = Mutex(State(scriptedCreateError: scriptedCreateError))
    }

    var createCalls: [CreateCall] { state.withLock { $0.createCalls } }
    /// Every `createTerminal` call, including those that threw; `createCalls` records only the ones that made a tab.
    var createAttempts: Int { state.withLock { $0.createAttempts } }
    var closedHandles: [TerminalHandle] { state.withLock { $0.closedHandles } }
    var terminals: [TerminalHandle: TerminalInfo] { state.withLock { $0.terminals } }
    var observedBeforeClose: [TerminalHandle: Bool] { state.withLock { $0.observedBeforeClose } }

    func scriptCreateError(_ error: WorkspaceError?) {
        state.withLock { $0.scriptedCreateError = error }
    }

    /// Makes every later `closeTerminal` fail with `error` after it has still ended the tab's login,
    /// so a test sees only the refusal and not a leaked process.
    func scriptCloseError(_ error: WorkspaceError?) {
        state.withLock { $0.scriptedCloseError = error }
    }

    func scriptProcessID(_ pid: pid_t?) {
        state.withLock { $0.scriptedProcessID = pid }
    }

    func scriptTerminalState(_ handle: TerminalHandle, _ state: WorkspaceTerminalState) {
        self.state.withLock { $0.terminalStates[handle] = state }
    }

    func scriptDefaultTerminalState(_ state: WorkspaceTerminalState?) {
        self.state.withLock { $0.defaultTerminalState = state }
    }

    func scriptTerminalError(_ handle: TerminalHandle, _ error: WorkspaceError) {
        self.state.withLock { $0.terminalErrors[handle] = error }
    }

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
        let error = state.withLock { lockedState -> WorkspaceError? in
            lockedState.createAttempts += 1
            return lockedState.scriptedCreateError
        }
        if let error {
            throw error
        }

        // Orca's terminal remains attached to an interactive login shell after its launcher exits.
        // Keep the fake login leader alive until closeTerminal simulates Orca closing the tab.
        let pid = try spawnCommandInFreshSession(command: "\(command); exec sleep 300")
        let (handle, reportedPID) = state.withLock { lockedState -> (TerminalHandle, pid_t) in
            let id = lockedState.nextID
            lockedState.nextID += 1
            let newHandle = TerminalHandle(rawValue: "tab-\(id)")
            lockedState.createCalls.append(CreateCall(worktreeID: worktreeID, title: title, command: command))
            let procID = lockedState.scriptedProcessID ?? pid
            lockedState.terminals[newHandle] = TerminalInfo(
                handle: newHandle, processID: procID, launcherProcessID: pid
            )
            return (newHandle, procID)
        }
        return WorkspaceTerminal(handle: handle, processID: reportedPID)
    }

    func terminal(_ handle: TerminalHandle) async throws(WorkspaceError) -> WorkspaceTerminalState {
        let (error, state) = self.state.withLock { lockedState -> (WorkspaceError?, WorkspaceTerminalState?) in
            let wasClosed = lockedState.closedHandles.contains(handle)
            lockedState.observedBeforeClose[handle] = !wasClosed
            // A closed tab reads as gone, the way `orca terminal show` answers for a closed handle.
            let error = wasClosed ? WorkspaceError.terminalNotFound(handle) : lockedState.terminalErrors[handle]
            let st = lockedState.terminalStates[handle] ?? lockedState.defaultTerminalState
            return (error, st)
        }
        if let error {
            throw error
        }
        if let state {
            return state
        }
        let termPid = self.terminals[handle]?.processID
        return WorkspaceTerminalState(orphaned: false, processID: termPid)
    }

    func closeTerminal(_ handle: TerminalHandle) async throws(WorkspaceError) {
        let (term, error) = state.withLock { lockedState -> (TerminalInfo?, WorkspaceError?) in
            lockedState.closedHandles.append(handle)
            return (lockedState.terminals[handle], lockedState.scriptedCloseError)
        }
        if let term {
            kill(term.launcherProcessID, SIGKILL)
            waitpid(term.launcherProcessID, nil, 0)
        }
        if let error {
            throw error
        }
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

final class OrcaTabPassFixture {
    let tempDir: URL
    let worktreeDir: URL
    let runsDir: URL
    let scriptPath: URL
    let sleepScriptPath: URL
    let exit143ScriptPath: URL
    let trapTermScriptPath: URL
    let trapTermMarkerURL: URL
    let exit1ScriptPath: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("orca-tab-pass-tests-\(UUID().uuidString)")
        self.tempDir = base
        self.worktreeDir = base.appendingPathComponent("worktree")
        self.runsDir = base.appendingPathComponent("runs")
        self.scriptPath = base.appendingPathComponent("fake-claude.sh")
        self.sleepScriptPath = base.appendingPathComponent("fake-claude-sleep.sh")
        self.exit143ScriptPath = base.appendingPathComponent("fake-claude-exit143.sh")
        self.trapTermScriptPath = base.appendingPathComponent("fake-claude-trap-term.sh")
        self.trapTermMarkerURL = base.appendingPathComponent("trap-term-started")
        self.exit1ScriptPath = base.appendingPathComponent("fake-claude-exit1.sh")

        try FileManager.default.createDirectory(at: worktreeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try writeScripts()
    }

    private func writeScripts() throws {
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

        let exit143Content = """
        #!/bin/sh
        exit 143
        """
        try exit143Content.write(to: exit143ScriptPath, atomically: true, encoding: .utf8)
        chmod(exit143ScriptPath.path, 0o755)

        let trapTermContent = """
        #!/bin/sh
        trap 'exit 143' TERM
        touch "\(trapTermMarkerURL.path)"
        while true; do
            sleep 0.05
        done
        """
        try trapTermContent.write(to: trapTermScriptPath, atomically: true, encoding: .utf8)
        chmod(trapTermScriptPath.path, 0o755)

        let exit1Content = """
        #!/bin/sh
        exit 1
        """
        try exit1Content.write(to: exit1ScriptPath, atomically: true, encoding: .utf8)
        chmod(exit1ScriptPath.path, 0o755)
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

    @Test("Operator closes tab mid-run ends external interruption, consumes Attempt (c1, c2, c4)")
    func operatorClosesTabMidRunEndsExternalInterruption() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.trapTermScriptPath, timeout: .seconds(30)
        )

        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-close", sessionName: "close-tab-session"
        )

        let task = Task {
            try await dispatch.dispatch(req)
        }

        while !FileManager.default.fileExists(atPath: fixture.trapTermMarkerURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let termHandle = TerminalHandle(rawValue: "tab-1")
        let term = try #require(workspace.terminals[termHandle])

        workspace.scriptTerminalState(termHandle, WorkspaceTerminalState(orphaned: true, processID: nil))

        kill(-term.processID, SIGTERM)

        let report = try await task.value
        // The engine still closes the tab the Operator closed: closing is unconditional (#798).
        #expect(workspace.closedHandles == [termHandle])

        guard case .crashedUnknown(.externalInterruption(let detail)) = report.outcome else {
            Issue.record("Expected .crashedUnknown(.externalInterruption(_)), got \(report.outcome)")
            return
        }
        #expect(detail.contains("the pass's Orca tab was closed"))
        #expect(detail.contains("wrapper received SIGTERM"))
        #expect(detail.contains("CLI exit 143"))

        let ending = try #require(AttemptEnding(failedRun: report.outcome))
        #expect(ending.consumesAttempt)
        #expect(!ending.excludesRoute)
        #expect(ending.classification == "external interruption: \(detail)")
        #expect(ending.consumedHow == "consumed; route not excluded (Crashed-Unknown, external interruption)")
        #expect(!ending.classification.hasPrefix(AttemptEnding.engineStoppedClassificationPrefix))
    }

    @Test("Login is gone while Orca is unreachable ends Crashed-Unknown external interruption (c1, c3)")
    func loginGoneWhileOrcaUnreachableIsExternalInterruption() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        var deadPID: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let argv = [strdup("/bin/echo"), strdup("hi"), nil]
        defer { for ptr in argv where ptr != nil { free(ptr) } }
        _ = posix_spawn(&deadPID, "/bin/echo", nil, &attr, argv, nil)
        waitpid(deadPID, nil, 0)
        #expect(kill(deadPID, 0) != 0)

        workspace.scriptProcessID(deadPID)
        workspace.scriptDefaultTerminalState(nil)
        let termHandle = TerminalHandle(rawValue: "tab-1")
        workspace.scriptTerminalError(termHandle, .unavailable("Orca daemon unreachable"))

        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.exit143ScriptPath, timeout: .seconds(10)
        )
        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-login-gone", sessionName: "login-gone-session"
        )
        let report = try await dispatch.dispatch(req)

        guard case .crashedUnknown(.externalInterruption(let detail)) = report.outcome else {
            Issue.record("Expected .crashedUnknown(.externalInterruption(_)), got \(report.outcome)")
            return
        }
        #expect(detail.contains("the pass's Orca tab was closed"))
        #expect(detail.contains("CLI exit 143"))
    }

    @Test("Outside kill of CLI inside still-attached tab keeps existing classification (c3)")
    func outsideKillInAttachedTabKeepsExistingClassification() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.exit143ScriptPath, timeout: .seconds(10)
        )
        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-attached", sessionName: "attached-tab-session"
        )
        let report = try await dispatch.dispatch(req)

        #expect(report.outcome == .failed(exitStatus: 143))
    }

    @Test("Timeout with tab gone afterwards stays timed out (c3)")
    func timeoutWithTabGoneStaysTimedOut() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        workspace.scriptDefaultTerminalState(WorkspaceTerminalState(orphaned: true, processID: nil))

        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.sleepScriptPath, timeout: .milliseconds(400)
        )
        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-timeout", sessionName: "timeout-session"
        )
        let report = try await dispatch.dispatch(req)

        #expect(report.outcome == .timedOut(after: .milliseconds(400)))
    }

    @Test("Completed pass whose tab is gone afterwards is external interruption (c3)")
    func completedPassWhoseTabIsGoneIsExternalInterruption() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        workspace.scriptDefaultTerminalState(WorkspaceTerminalState(orphaned: true, processID: nil))

        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.scriptPath, timeout: .seconds(10)
        )
        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-completed", sessionName: "completed-session"
        )
        let report = try await dispatch.dispatch(req)

        guard case .crashedUnknown(.externalInterruption) = report.outcome else {
            Issue.record("Expected external interruption, got \(report.outcome)")
            return
        }
        #expect(report.session == "sess-tab-1")
    }

    @Test("Direct spawn pass is never classified as external interruption (c3)")
    func directSpawnPassNeverClassifiedAsExternalInterruption() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        workspace.scriptDefaultTerminalState(WorkspaceTerminalState(orphaned: true, processID: nil))

        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.exit143ScriptPath, timeout: .seconds(10)
        )
        let req = fixture.makeRequest(
            pass: .worker, worktreeID: nil, sessionName: "direct-session"
        )
        let report = try await dispatch.dispatch(req)

        #expect(workspace.createCalls.isEmpty)
        #expect(report.outcome == .failed(exitStatus: 143))
    }

    @Test("Tab observation happens before the host close (c1)")
    func tabObservationHappensBeforeHostClose() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: fixture.scriptPath, timeout: .seconds(10)
        )
        let req = fixture.makeRequest(
            pass: .worker, worktreeID: "wt-obs", sessionName: "obs-session"
        )
        let report = try await dispatch.dispatch(req)

        #expect(report.outcome.isCompleted)
        let termHandle = TerminalHandle(rawValue: "tab-1")
        #expect(workspace.observedBeforeClose[termHandle] == true)
        #expect(workspace.closedHandles.contains(termHandle))
    }
}
