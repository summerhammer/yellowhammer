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
    public let recorder: (any DispatchPromptRecording)?
    public let now: @Sendable () -> Date

    public init(
        process: AgentCLIProcess = AgentCLIProcess(),
        recorder: (any DispatchPromptRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.process = process
        self.recorder = recorder
        self.now = now
    }

    public func run(_ dispatch: CLIDispatch, adapter: some CLIAdapter) async throws -> CLIRunReport {
        let promptRecord = capturePromptRecord(for: dispatch, adapter: adapter)

        let launch: AgentCLILaunch
        do {
            launch = try adapter.launch(for: dispatch)
        } catch {
            if let promptRecord, let recorder {
                _ = recorder.markLaunch(.notLaunched(cause: error.description), of: promptRecord)
            }
            throw error
        }

        // Every path out of here, including a failed spawn, passes through this defer.
        defer {
            for file in launch.scratchFiles { try? FileManager.default.removeItem(at: file) }
        }

        // Marked at spawn, not at exit: the record reads "launched" for the whole run, and a yh killed
        // mid-run leaves it launched rather than pending forever. `execute` throws only before the spawn.
        let onSpawn: (@Sendable () -> Void)? = if let promptRecord, let recorder {
            { _ = recorder.markLaunch(.launched, of: promptRecord) }
        } else {
            nil
        }
        let execution: AgentCLIExecution
        do {
            execution = try await process.execute(launch, onSpawn: onSpawn)
        } catch {
            if let promptRecord, let recorder {
                _ = recorder.markLaunch(.notLaunched(cause: error.description), of: promptRecord)
            }
            throw error
        }

        let session = adapter.collect(end: execution.end, dispatch: dispatch)
        let outcome: RunOutcome
        if case .exited(let status) = execution.end, status != 0,
           let refusal = adapter.usageLimit(for: dispatch) {
            outcome = refusal
        } else {
            outcome = RunOutcome.classify(end: execution.end, resultFileAt: launch.resultFile, pass: dispatch.pass)
        }
        return CLIRunReport(
            pid: execution.pid, end: execution.end, outcome: outcome, session: session,
            leftovers: execution.leftovers, snapshot: execution.snapshot
        )
    }

    private func capturePromptRecord(for dispatch: CLIDispatch, adapter: some CLIAdapter) -> DispatchPromptRecord? {
        guard let provenance = dispatch.provenance, let recorder else { return nil }
        let record = DispatchPromptRecord(
            provenance: provenance,
            route: dispatch.route.description,
            pass: dispatch.pass,
            dispatchedAt: now(),
            defaultVersion: provenance.family.defaultVersion,
            projectInstructions: dispatch.projectInstructions,
            session: dispatch.resume != nil ? .resumed : .new,
            instruction: dispatch.instruction,
            outputSchema: adapter.outputSchema(for: dispatch.pass),
            launch: .pending
        )
        _ = recorder.capture(record)
        return record
    }
}
