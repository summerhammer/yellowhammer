import Darwin
import Domain
import Foundation

/// One completed agent CLI run: the process identity the lifecycle observed, how it ended, and the
/// dual-key completion verdict derived from that ending plus the result file. `pid`/`processGroup`
/// name the CLI leader only — on a forced termination, the descendants swept alongside it
/// (``ProcessTree``) are not reported here; they are contained, not tracked past that.
public struct AgentCLIRunReport: Equatable, Sendable {
    public let pid: pid_t
    /// Equal to `pid`: the CLI leads its own process group.
    public let processGroup: pid_t
    public let end: RunEnd
    public let outcome: RunOutcome
}

/// The process identity and ending of one run, before the dual-key completion verdict is applied.
/// A CLI Adapter (P7.3) needs this gap — it reads and materializes structured output, and resolves
/// which session to resume next, between the process ending and the dual-key check.
public struct AgentCLIExecution: Equatable, Sendable {
    public let pid: pid_t
    /// Equal to `pid`: the CLI leads its own process group.
    public let processGroup: pid_t
    public let end: RunEnd
}

/// Why ``AgentCLIProcess/run(_:)`` could not even start a run.
public enum AgentCLILaunchError: Error, Equatable, Sendable, CustomStringConvertible {
    case worktreeMissing(String)
    case spawnFailed(errno: Int32, executable: String)

    public var description: String {
        switch self {
        case .worktreeMissing(let path):
            "worktree missing: \(path)"
        case .spawnFailed(let errno, let executable):
            "posix_spawn failed for \(executable): errno \(errno)"
        }
    }
}

/// Runs one agent CLI in its own process group inside the Worktree and applies the dual-key
/// completion contract (spec: the CLI Adapter spawns via `posix_spawn` +
/// `POSIX_SPAWN_SETPGROUP`; on timeout or engine-initiated abort it sends `SIGTERM` to the
/// group, grants a grace window, then `SIGKILL`s the group). Group signals alone are not enough:
/// a real CLI's tool commands routinely escape into a new session or process group of their own
/// (claude's Bash tool calls `setsid`; codex makes the tool command a group leader), so
/// termination (`AgentCLIProcess+Termination.swift`) also snapshots and signals the CLI's
/// descendant process tree directly, by pid identity — see ``ProcessTree``.
public struct AgentCLIProcess: Sendable {
    /// Spec-mandated 3 s. Configurable only so tests can shorten it.
    public let gracePeriod: Duration
    public let pollInterval: Duration

    public init(gracePeriod: Duration = .seconds(3), pollInterval: Duration = .milliseconds(20)) {
        self.gracePeriod = gracePeriod
        self.pollInterval = pollInterval
    }

    public func run(_ launch: AgentCLILaunch) async throws(AgentCLILaunchError) -> AgentCLIRunReport {
        let execution = try await execute(launch)
        let outcome = RunOutcome.classify(end: execution.end, resultFileAt: launch.resultFile, pass: launch.pass)
        return AgentCLIRunReport(
            pid: execution.pid, processGroup: execution.processGroup, end: execution.end, outcome: outcome
        )
    }

    /// Spawns and waits for `launch`, stopping short of the dual-key verdict. A CLI Adapter calls
    /// this directly so it can read and materialize structured output, and resolve which session to
    /// resume next, before ``RunOutcome/classify(end:resultFileAt:pass:)`` runs.
    public func execute(_ launch: AgentCLILaunch) async throws(AgentCLILaunchError) -> AgentCLIExecution {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: launch.worktreePath, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw .worktreeMissing(launch.worktreePath)
        }

        let spawnOutcome = ProcessGroup.spawn(
            executable: launch.executable,
            arguments: launch.arguments,
            environment: launch.environment,
            worktreePath: launch.worktreePath,
            outputPath: launch.outputLog?.path,
            standardOutputPath: launch.standardOutput?.path
        )
        let pid: pid_t
        switch spawnOutcome {
        case .success(let spawnedPID):
            pid = spawnedPID
        case .failure(let errorCode):
            throw .spawnFailed(errno: errorCode, executable: launch.executable)
        }

        let end = await wait(pid: pid, timeout: launch.timeout)
        return AgentCLIExecution(pid: pid, processGroup: pid, end: end)
    }

    // MARK: - Waiting

    /// Polls `waitpid(WNOHANG)` in the calling task (never a detached one) so `Task.isCancelled`
    /// stays observable, until the leader exits, the engine cancels, or `timeout` elapses.
    private func wait(pid: pid_t, timeout: Duration) async -> RunEnd {
        let clock = ContinuousClock()
        let start = clock.now

        while true {
            if let end = ProcessGroup.reapNonBlocking(pid: pid) {
                return end
            }
            if Task.isCancelled {
                return await terminate(pid: pid, reason: .aborted)
            }
            if clock.now - start >= timeout {
                return await terminate(pid: pid, reason: .timedOut(after: timeout))
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Why a run is being ended by Yellowhammer rather than the CLI's own exit — shared with
    /// `AgentCLIProcess+Termination.swift`, where the actual signalling and reaping lives.
    enum TerminationReason {
        case timedOut(after: Duration)
        case aborted
    }
}
