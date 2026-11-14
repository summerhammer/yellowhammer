import Darwin
import Domain
@testable import EngineCommand
import Foundation
import ProcessTestSupport
import Repositories
import Testing

/// Issue #798: the engine closes each Work Card pass's Orca tab after the pass, whatever its ending, and
/// never another tab; an interactive agent Orca reopens in the Worktree is the Operator's terminal, left
/// to the Act-start, retry and Block fences (ADR-007 item 8 and Consequences; Orca Session Visibility
/// Ruling, item 3).
@Suite("Orca tab close after a Work Card pass", .timeLimit(.minutes(1)))
struct OrcaTabCloseTests {
    /// The pass endings this suite drives without choreography. External interruption and a cancelled
    /// dispatch are asserted in `OrcaTabPassTests`.
    enum Ending: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case completed
        case failed
        case killedFromOutside
        case timedOut

        var testDescription: String { rawValue }

        func script(in fixture: OrcaTabPassFixture) -> URL {
            switch self {
            case .completed: fixture.scriptPath
            case .failed: fixture.exit1ScriptPath
            case .killedFromOutside: fixture.exit143ScriptPath
            case .timedOut: fixture.sleepScriptPath
            }
        }

        var timeout: Duration {
            self == .timedOut ? .milliseconds(400) : .seconds(10)
        }

        func matches(_ outcome: RunOutcome) -> Bool {
            switch self {
            case .completed: outcome.isCompleted
            case .failed: outcome == .failed(exitStatus: 1)
            case .killedFromOutside: outcome == .failed(exitStatus: 143)
            case .timedOut: outcome == .timedOut(after: .milliseconds(400))
            }
        }
    }

    @Test("After the pass, Orca reports its tab gone, whatever the pass's ending", arguments: Ending.allCases)
    func tabIsClosedAfterEveryEnding(_ ending: Ending) async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(
            workspace: workspace, scriptURL: ending.script(in: fixture), timeout: ending.timeout
        )
        let report = try await dispatch.dispatch(
            fixture.makeRequest(pass: .worker, worktreeID: "wt-close", sessionName: "close-\(ending.rawValue)")
        )

        #expect(ending.matches(report.outcome), "got \(report.outcome)")
        let handle = TerminalHandle(rawValue: "tab-1")
        #expect(workspace.closedHandles == [handle])
        await #expect(throws: WorkspaceError.terminalNotFound(handle)) {
            _ = try await workspace.terminal(handle)
        }
        let login = try #require(workspace.terminals[handle])
        #expect(kill(login.processID, 0) != 0)
    }

    @Test("Orca refusing the close changes neither the pass's outcome nor its report")
    func closeFailureKeepsTheOutcome() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        workspace.scriptCloseError(.refused(code: "terminal_busy", message: "close refused"))
        let dispatch = try fixture.makeDispatch(workspace: workspace)

        let report = try await dispatch.dispatch(
            fixture.makeRequest(pass: .worker, worktreeID: "wt-refused", sessionName: "close-refused")
        )

        #expect(report.outcome.isCompleted, "got \(report.outcome)")
        #expect(report.session == "sess-tab-1")
        #expect(report.notShownInOrca == nil)
        #expect(workspace.closedHandles == [TerminalHandle(rawValue: "tab-1")])
    }

    @Test("Closing the pass's tab leaves the Operator's other Orca tab in the Worktree open")
    func closeLeavesOtherTabsInTheWorktree() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let operatorTab = try await workspace.createTerminal(
            worktreeID: WorktreeID(rawValue: "wt-shared"), title: "operator", command: "sleep 30"
        )
        let operatorLogin = try #require(operatorTab.processID)
        defer {
            kill(operatorLogin, SIGKILL)
            waitpid(operatorLogin, nil, 0)
        }

        let dispatch = try fixture.makeDispatch(workspace: workspace)
        let report = try await dispatch.dispatch(
            fixture.makeRequest(pass: .worker, worktreeID: "wt-shared", sessionName: "pass-tab")
        )

        #expect(report.outcome.isCompleted)
        let passTab = TerminalHandle(rawValue: "tab-2")
        #expect(workspace.createCalls.map(\.title) == ["operator", "pass-tab"])
        #expect(workspace.closedHandles == [passTab])
        #expect(kill(operatorLogin, 0) == 0)
        let operatorState = try await workspace.terminal(operatorTab.handle)
        #expect(!operatorState.orphaned)
    }

    /// Orca reopens a dead agent tab as `claude --resume` in its own terminal session, after the pass
    /// has ended: never a descendant of the pass, and in none of its recorded sessions or groups.
    @Test("An interactive claude Orca reopens is not the pass's, and the Act-start fence kills it")
    func reopenedInteractiveClaudeIsFencedAtActStart() async throws {
        let fixture = try OrcaTabPassFixture()
        defer { fixture.cleanUp() }

        let workspace = FakeTabWorkspace()
        let dispatch = try fixture.makeDispatch(workspace: workspace)
        let report = try await dispatch.dispatch(
            fixture.makeRequest(pass: .worker, worktreeID: "wt-reopen", sessionName: "reopen-session")
        )
        #expect(report.outcome.isCompleted)
        #expect(workspace.closedHandles == [TerminalHandle(rawValue: "tab-1")])
        let snapshot = try #require(report.snapshot)

        let claude = fixture.tempDir.appending(component: "claude")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: claude.path)
        // A bare copy of a platform binary keeps Apple's platform signature, which is invalid at the new
        // path: the kernel kills it with SIGKILL (Code Signature Invalid) a fraction of a second after it
        // starts, so under load it was dead before the fences ran. An ad-hoc signature keeps it running,
        // and a copy (not a `#!` script, which reads as its interpreter) keeps its command name `claude`.
        try Self.adHocSign(claude)
        let reopened = try SpawnedChild.spawn(
            executable: claude.path, arguments: ["30"], currentDirectory: fixture.worktreeDir, newSession: true
        )
        defer { reopened.terminateAndReap() }
        try await Self.waitUntilHolds(fixture.worktreeDir.path, pid: reopened.pid)

        let fencer = ProcessFencer(quiescenceTimeout: .seconds(2))
        let normalExit = await fencer.fence(worktreePath: fixture.worktreeDir.path, attributedTo: snapshot)
        guard case .quiescent(let killed, let unattributed) = normalExit else {
            Issue.record("Expected the normal-exit fence to be quiescent, got \(normalExit)")
            return
        }
        #expect(killed.isEmpty)
        #expect(unattributed.map(\.pid) == [reopened.pid])
        #expect(unattributed.first?.commandName == "claude")
        #expect(reopened.isRunning)

        // The Act-start fence (WorktreeReconciler), the retry fence (AttemptResetting) and the Block fence
        // all fence the Worktree without attribution: every holder is killed.
        let actStart = await fencer.fence(worktreePath: fixture.worktreeDir.path)
        guard case .quiescent(let fenced) = actStart else {
            Issue.record("Expected the Act-start fence to be quiescent, got \(actStart)")
            return
        }
        #expect(fenced.map(\.pid) == [reopened.pid])
        #expect(await reopened.waitForExit(timeout: .seconds(5)) == .signalled(SIGKILL))
    }

    private static func adHocSign(_ executable: URL) throws {
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--force", "--sign", "-", executable.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        try #require(codesign.terminationStatus == 0, "codesign failed to re-sign \(executable.path)")
    }

    private static func waitUntilHolds(_ worktreePath: String, pid: pid_t) async throws {
        let fencer = ProcessFencer()
        let deadline = ContinuousClock.now + .seconds(5)
        while !fencer.holders(of: worktreePath).contains(where: { $0.pid == pid }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("The reopened claude never held \(worktreePath)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
