import Darwin
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
    /// Whether the engine itself sent a termination signal (timeout, abort or prompt).
    public let engineSignalled: Bool
    /// Signals the wrapper received while the CLI ran, in order.
    public let receivedSignals: [Int32]
    /// Whether the pass's Orca tab was observed gone after the CLI ended (nil for direct spawn).
    public let tabGone: Bool?
    public let tabInterruption: TabInterruptionEvidence?

    public init(
        pid: pid_t,
        end: RunEnd,
        outcome: RunOutcome,
        session: CLISession?,
        leftovers: [LeftoverProcess],
        snapshot: RunningSnapshot,
        engineSignalled: Bool = false,
        receivedSignals: [Int32] = [],
        tabGone: Bool? = nil, tabInterruption: TabInterruptionEvidence? = nil
    ) {
        self.pid = pid
        self.end = end
        self.outcome = outcome
        self.session = session
        self.leftovers = leftovers
        self.snapshot = snapshot
        self.engineSignalled = engineSignalled
        self.receivedSignals = receivedSignals
        self.tabGone = tabGone
        self.tabInterruption = tabInterruption
    }
}

/// Drives one CLI Adapter through a full pass: build the launch, run it, let the adapter collect
/// its session before the dual-key check runs. Cancellation-aware exactly as ``AgentCLIProcess`` —
/// it does no polling or waiting of its own.
public struct CLIRunner: Sendable {
    public typealias LauncherStarter = @Sendable (_ launcherURL: URL) async throws -> Void
    public typealias TabObserver = @Sendable () async -> Bool
    public typealias TabEvidenceObserver = @Sendable () async -> TabInterruptionEvidence

    public let process: AgentCLIProcess
    public let recorder: (any DispatchPromptRecording)?
    public let now: @Sendable () -> Date
    public let launcherStarter: LauncherStarter?
    public let tabObserver: TabObserver?
    public let tabEvidenceObserver: TabEvidenceObserver?

    public init(
        process: AgentCLIProcess = AgentCLIProcess(),
        recorder: (any DispatchPromptRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        launcherStarter: LauncherStarter? = nil,
        tabObserver: TabObserver? = nil, tabEvidenceObserver: TabEvidenceObserver? = nil
    ) {
        self.process = process
        self.recorder = recorder
        self.now = now
        self.launcherStarter = launcherStarter
        self.tabObserver = tabObserver
        self.tabEvidenceObserver = tabEvidenceObserver
    }

    public func run(
        _ dispatch: CLIDispatch,
        adapter: some CLIAdapter,
        launcherStarter: LauncherStarter? = nil,
        tabObserver: TabObserver? = nil,
        tabEvidenceObserver: TabEvidenceObserver? = nil
    ) async throws -> CLIRunReport {
        let promptRecord = capturePromptRecord(for: dispatch, adapter: adapter)

        let launch: AgentCLILaunch
        do {
            launch = try adapter.launch(for: dispatch)
        } catch {
            if let promptRecord, let recorder {
                _ = recorder.markLaunch(.notLaunched(cause: String(describing: error)), of: promptRecord)
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
        let starter = launcherStarter ?? self.launcherStarter
        let observer = tabObserver ?? self.tabObserver
        let execution: AgentCLIExecution
        do {
            if let starter {
                execution = try await process.executeWrapped(
                    launch,
                    runDirectory: dispatch.runDirectory,
                    onSpawn: onSpawn,
                    tabObserver: observer,
                    tabEvidenceObserver: tabEvidenceObserver ?? self.tabEvidenceObserver,
                    startLauncher: starter
                )
            } else {
                execution = try await process.execute(launch, onSpawn: onSpawn)
            }
        } catch {
            if let promptRecord, let recorder {
                _ = recorder.markLaunch(.notLaunched(cause: String(describing: error)), of: promptRecord)
            }
            throw error
        }

        let session = adapter.collect(end: execution.end, dispatch: dispatch)
        let outcome = classifyOutcome(execution, launch: launch, dispatch: dispatch, adapter: adapter)
        return CLIRunReport(
            pid: execution.pid, end: execution.end, outcome: outcome, session: session,
            leftovers: execution.leftovers, snapshot: execution.snapshot,
            engineSignalled: execution.engineSignalled, receivedSignals: execution.receivedSignals,
            tabGone: execution.tabGone, tabInterruption: execution.tabInterruption
        )
    }

    private func classifyOutcome(
        _ execution: AgentCLIExecution,
        launch: AgentCLILaunch,
        dispatch: CLIDispatch,
        adapter: some CLIAdapter
    ) -> RunOutcome {
        var outcome: RunOutcome
        if case .exited(let status) = execution.end, status != 0,
           let refusal = adapter.usageLimit(for: dispatch) {
            outcome = refusal
        } else {
            outcome = RunOutcome.classify(end: execution.end, resultFileAt: launch.resultFile, pass: dispatch.pass)
        }
        let engineStop: Bool = switch execution.end {
        case .timedOut, .aborted, .promptBlocked: true
        default: false
        }
        let tabProvesInterruption = execution.tabInterruption?.provesInterruption == true
            || (execution.tabInterruption == nil && execution.tabGone == true)
        if !engineStop, !execution.engineSignalled, tabProvesInterruption {
            let detail = Self.externalInterruptionDetail(
                end: execution.end, receivedSignals: execution.receivedSignals
            )
            outcome = .crashedUnknown(.externalInterruption(detail))
        }
        return outcome
    }

    static func externalInterruptionDetail(
        end: RunEnd, receivedSignals: [Int32]
    ) -> String {
        var parts: [String] = []
        if !receivedSignals.isEmpty {
            let sigNames = receivedSignals.map { signalName($0) }.joined(separator: ", ")
            parts.append("wrapper received \(sigNames)")
        }
        switch end {
        case .exited(let status):
            parts.append("CLI exit \(status)")
        case .signaled(let signal):
            parts.append("CLI signaled \(signalName(signal))")
        case .crashedUnknown(let cause):
            parts.append("CLI crashed (\(cause))")
        case .timedOut(let after, _):
            parts.append("timed out after \(after.wholeMinutes) min")
        case .aborted:
            parts.append("aborted")
        case .promptBlocked(let detail, _):
            parts.append("prompt blocked: \(detail)")
        }
        if parts.isEmpty {
            return "the pass's Orca tab was closed"
        } else {
            return "the pass's Orca tab was closed (\(parts.joined(separator: ", ")))"
        }
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGKILL: "SIGKILL"
        case SIGPIPE: "SIGPIPE"
        case SIGUSR1: "SIGUSR1"
        case SIGUSR2: "SIGUSR2"
        default: "signal \(signal)"
        }
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
