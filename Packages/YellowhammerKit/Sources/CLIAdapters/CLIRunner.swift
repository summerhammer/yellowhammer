import Domain
import Foundation

/// One CLI Adapter run, end to end: the process identity and ending, the dual-key verdict, and the
/// session to resume next (if the adapter offered one).
public struct CLIRunReport: Equatable, Sendable {
    public let pid: pid_t
    public let end: RunEnd
    public let outcome: RunOutcome
    public let session: CLISession?
    /// See ``AgentCLIRunReport/leftovers``.
    public let leftovers: [LeftoverProcess]
    /// See ``AgentCLIRunReport/snapshot``.
    public let snapshot: RunningSnapshot
}

/// Drives one CLI Adapter through a full pass: build the launch, run it, let the adapter collect
/// its session before the dual-key check runs. Cancellation-aware exactly as ``AgentCLIProcess`` —
/// it does no polling or waiting of its own.
public struct CLIRunner: Sendable {
    public let process: AgentCLIProcess

    public init(process: AgentCLIProcess = AgentCLIProcess()) {
        self.process = process
    }

    public func run(_ dispatch: CLIDispatch, adapter: some CLIAdapter) async throws -> CLIRunReport {
        let launch = try adapter.launch(for: dispatch)
        let execution = try await process.execute(launch)
        let session = adapter.collect(end: execution.end, dispatch: dispatch)
        let outcome = RunOutcome.classify(end: execution.end, resultFileAt: launch.resultFile, pass: dispatch.pass)
        return CLIRunReport(
            pid: execution.pid, end: execution.end, outcome: outcome, session: session,
            leftovers: execution.leftovers, snapshot: execution.snapshot
        )
    }
}
