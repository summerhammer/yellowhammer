import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("Permission prompt ending with Orca tab evidence", .timeLimit(.minutes(1)))
struct CLIRunnerPromptWithTabEvidenceTests {
    private struct TestAdapter: CLIAdapter {
        let cli = "test"
        let adapterVersion = "1.0"
        let supportedEfforts = ["medium"]
        let scriptPath: String
        let resultFile: URL

        func outputSchema(for pass: RunPass) -> String { "" }

        func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
            AgentCLILaunch(
                executable: scriptPath,
                arguments: [resultFile.path, dispatch.runDirectory.appendingPathComponent("scratch").path],
                environment: [:],
                worktreePath: dispatch.worktreePath,
                resultFile: resultFile,
                pass: dispatch.pass,
                timeout: dispatch.timeout
            )
        }

        func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession? { nil }
    }

    @Test("A permission prompt stays an engine stop when the tab is missing")
    func permissionPromptWithMissingTab() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-prompt-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
        #!/bin/sh
        echo $$ > "\(pidFile.path)"
        while :; do sleep 1; done
        """
        let fixture = try StubAgentCLI.makeFixture(script: script)
        defer { fixture.cleanUp() }
        let wrapper = try passWrapperChildURL()
        let route = Route(cli: "test", model: "default", effort: "medium")!
        let dispatch = CLIDispatch(
            route: route,
            pass: .worker,
            instruction: "test",
            worktreePath: fixture.worktree.path,
            runDirectory: fixture.tempDir,
            timeout: .seconds(30),
            executable: fixture.scriptPath.path
        )
        let tracker = PIDTracker()
        defer { tracker.reapAll() }
        let runner = CLIRunner(
            process: AgentCLIProcess(
                gracePeriod: .milliseconds(100), pollInterval: .milliseconds(20),
                promptSource: MarkerPromptSource(pidFile: pidFile), wrapperExecutable: wrapper.path
            ),
            launcherStarter: { launcherURL in
                let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
                tracker.add(pid)
            },
            tabEvidenceObserver: {
                TabInterruptionEvidence(tabState: .missing, loginState: .dead)
            }
        )

        let report = try await runner.run(
            dispatch,
            adapter: TestAdapter(scriptPath: fixture.scriptPath.path, resultFile: fixture.resultFile)
        )

        guard case .crashedUnknown(.engineStopped(let cause)) = report.outcome else {
            Issue.record("Expected a permission prompt engine stop, got \(report.outcome)")
            return
        }
        #expect(cause.hasPrefix(CrashedUnknownCause.permissionPromptCausePrefix))
        #expect(report.engineSignalled)
        #expect(report.tabInterruption == TabInterruptionEvidence(tabState: .missing, loginState: .dead))
    }
}

private struct MarkerPromptSource: PromptSource {
    let pidFile: URL
    func start() async -> (any PromptWatching)? { MarkerPromptWatch(pidFile: pidFile) }
}

private actor MarkerPromptWatch: PromptWatching {
    let pidFile: URL
    var delivered = false

    init(pidFile: URL) { self.pidFile = pidFile }

    func drain() async -> [PromptEvent] {
        guard !delivered,
              let contents = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return [] }
        delivered = true
        return [PromptEvent(kind: .keychain, clientPID: pid, detail: "test Keychain prompt")]
    }

    func stop() async {}
}
