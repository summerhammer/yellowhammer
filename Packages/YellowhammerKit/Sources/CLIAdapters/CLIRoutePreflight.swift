import Domain
import Foundation

/// A Route Pre-flight on one CLI (OQ126): the Probe's unattended dispatch, run once on the whole Route
/// — that model and that effort — in a scratch `git init`ed directory, on the Probe's trivial prompt.
/// The Probe establishes that a CLI works; this establishes that it accepts the Route. It passes on a
/// clean exit, exactly as the Probe's unattended-dispatch finding does: a CLI that rejects a model
/// exits non-zero, and what it printed is the reason. Never throws, like the Probe.
public struct CLIRoutePreflight: Sendable {
    public let timeout: Duration
    public let recorder: (any DispatchPromptRecording)?

    public init(timeout: Duration = .seconds(300), recorder: (any DispatchPromptRecording)? = nil) {
        self.timeout = timeout
        self.recorder = recorder
    }

    /// Nil when the Route passed; otherwise why it did not, Operator-facing.
    public func run(
        adapter: some CLIAdapter,
        route: Route,
        executable: String,
        environment: [String: String],
        workDirectory: URL,
        projectID: String? = nil,
        runID: String? = nil,
        nightID: Int64? = nil,
        recordID: String? = nil
    ) async -> String? {
        let worktree = workDirectory.appendingPathComponent("worktree")
        let runDirectory = workDirectory.appendingPathComponent("run")
        do {
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        } catch {
            return "could not create the pre-flight directory: \(error)"
        }
        guard await CLIProbe.runGitInit(in: worktree) else {
            return "`git init -q` did not succeed in \(worktree.path)"
        }
        let probe = CLIProbe(dispatchTimeout: timeout, recorder: recorder, protectedDirectories: [])
        // The pre-flight prompt runs no command, so it carries no protected directories.
        let context = ProbeDispatchContext(
            route: route, executable: executable, environment: environment, worktree: worktree,
            runsDirectory: workDirectory, protectedDirectories: [],
            projectID: projectID, runID: runID, nightID: nightID, recordID: recordID
        )
        let result = await probe.runDispatch(
            pass: .architect, family: .routePreflight, adapter: adapter, context: context, runDirectory: runDirectory,
            instruction: CLIProbe.unattendedInstruction(nonce: CLIProbe.makeNonce()), resume: nil
        )
        let (finding, detail) = CLIProbe.unattendedFinding(for: result, runDirectory: runDirectory)
        guard finding != .passed else { return nil }
        return "`\(route.cli)` did not run `\(route)`: \(detail ?? "no reason given")"
    }
}
