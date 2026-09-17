@testable import CLIAdapters
import Domain
import Foundation

/// A test-only ``CLIAdapter`` standing in for a real agent CLI in ``CLIProbeTests``: its `launch`
/// hands its stub `/bin/sh` executable the instruction, pass and resume session as plain argv, and
/// its `collect` reads back two conventions the stub writes to stdout — `SESSION:<id>` and
/// `RESULT:<json>` — mirroring how the real adapters read structured stdout and materialize
/// `result.json`.
struct StubProbeAdapter: CLIAdapter {
    let cli = "stub"
    let adapterVersion = "test"
    let supportedEfforts = ["low"]

    func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
        try validateRoute(dispatch)
        let resultFile = try prepareRunDirectory(dispatch)
        let arguments = [dispatch.instruction, dispatch.pass.rawValue, dispatch.resume?.rawValue ?? ""]

        return AgentCLILaunch(
            executable: dispatch.executable,
            arguments: arguments,
            environment: dispatch.environment,
            worktreePath: dispatch.worktreePath,
            resultFile: resultFile,
            pass: dispatch.pass,
            timeout: dispatch.timeout,
            outputLog: dispatch.runDirectory.appendingPathComponent("stderr.log"),
            standardOutput: dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        )
    }

    func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession? {
        let stdoutFile = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let data = try? Data(contentsOf: stdoutFile), let text = String(data: data, encoding: .utf8) else {
            return dispatch.resume
        }

        var session = dispatch.resume
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("SESSION:") {
                session = CLISession(rawValue: String(line.dropFirst("SESSION:".count)))
            } else if line.hasPrefix("RESULT:") {
                let json = String(line.dropFirst("RESULT:".count))
                let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
                try? Data(json.utf8).write(to: resultFile)
            }
        }
        return session
    }

    private static let stdoutFileName = "stdout.txt"
}
