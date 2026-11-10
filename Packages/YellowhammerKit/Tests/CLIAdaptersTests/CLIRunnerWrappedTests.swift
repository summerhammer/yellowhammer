import CLIAdapters
import Domain
import Foundation
import Testing

@Suite("CLIRunner on wrapped path", .timeLimit(.minutes(1)))
struct CLIRunnerWrappedTests {
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

    @Test("CLIRunner runs on wrapped path when launcherStarter is provided")
    func cliRunnerWrappedDispatch() async throws {
        let wrapperURL = try passWrapperChildURL()
        let fixture = try StubAgentCLI.makeFixture(script: StubAgentCLI.cleanExit)
        defer { fixture.cleanUp() }

        let tracker = PIDTracker()
        defer { tracker.reapAll() }

        let route = Route(cli: "test", model: "default", effort: "medium")!
        let dispatch = CLIDispatch(
            route: route,
            pass: .worker,
            instruction: "test",
            worktreePath: fixture.worktree.path,
            runDirectory: fixture.tempDir,
            timeout: .seconds(5),
            executable: fixture.scriptPath.path
        )

        let runner = CLIRunner(
            process: AgentCLIProcess(wrapperExecutable: wrapperURL.path),
            launcherStarter: { launcherURL in
                let pid = try spawnLauncherInFreshSession(launcherURL: launcherURL)
                tracker.add(pid)
            }
        )

        let report = try await runner.run(
            dispatch,
            adapter: TestAdapter(scriptPath: fixture.scriptPath.path, resultFile: fixture.resultFile)
        )

        #expect(report.end == .exited(status: 0))
        #expect(report.outcome.isWrappedCompleted)
        #expect(report.engineSignalled == false)
        #expect(report.pid > 0)
        #expect(report.receivedSignals.isEmpty)
    }
}
