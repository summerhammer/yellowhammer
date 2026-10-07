import Darwin
import Domain
import Foundation

/// One completed agent CLI run: the process identity the lifecycle observed, how it ended, and the
/// dual-key completion verdict derived from that ending plus the result file. `pid`/`processGroup`
/// name the CLI leader only. On a forced termination, the descendants swept alongside it
/// (``ProcessTree``) are contained but not reported (``leftovers`` is `[]`); on a normal exit, they
/// are both swept and reported in ``leftovers`` (Normal-Exit Sweep Ruling).
public struct AgentCLIRunReport: Equatable, Sendable {
    public let pid: pid_t
    /// Equal to `pid`: the CLI leads its own process group.
    public let processGroup: pid_t
    public let end: RunEnd
    public let outcome: RunOutcome
    /// Background tool processes still running after a NORMAL exit, swept by identity (Normal-Exit
    /// Sweep Ruling) — empty on a forced termination (timeout or abort), where `terminate()`
    /// contains descendants but does not report them.
    public let leftovers: [LeftoverProcess]
    /// The running snapshot this run's lifecycle captured (Normal-Exit Sweep Ruling): the CLI's
    /// descendant tree, walked while its leader was still alive, that the attributed Worktree
    /// fence uses to tell this run's processes apart from an unrelated one sharing the Worktree.
    /// Present on every ending — normal exit, timeout, or abort — since the cumulative descendant
    /// walk that feeds it runs regardless of how the run ends.
    public let snapshot: RunningSnapshot
}

/// The process identity and ending of one run, before the dual-key completion verdict is applied.
/// A CLI Adapter (P7.3) needs this gap — it reads and materializes structured output, and resolves
/// which session to resume next, between the process ending and the dual-key check.
public struct AgentCLIExecution: Equatable, Sendable {
    public let pid: pid_t
    /// Equal to `pid`: the CLI leads its own process group.
    public let processGroup: pid_t
    public let end: RunEnd
    /// See ``AgentCLIRunReport/leftovers``.
    public let leftovers: [LeftoverProcess]
    /// See ``AgentCLIRunReport/snapshot``.
    public let snapshot: RunningSnapshot
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
            "posix_spawn failed for \(executable): \(String(cString: strerror(errno))) (errno \(errno))"
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
/// descendant process tree directly, by pid identity — see ``ProcessTree``. A NORMAL exit gets the
/// same treatment (Normal-Exit Sweep Ruling): macOS reparents a process's children to `launchd` at
/// its *exit*, not at its reap, so a tree walk after the leader is reaped finds nothing — the
/// running descendant snapshot below is what makes a post-exit sweep possible at all.
public struct AgentCLIProcess: Sendable {
    /// Spec-mandated 3 s. Configurable only so tests can shorten it.
    public let gracePeriod: Duration
    public let pollInterval: Duration
    /// How often `wait` re-walks the CLI's descendant tree while it is still alive, folding
    /// results into a cumulative snapshot. Not a config key — an unnamed bound, tunable only from
    /// tests. Must poll faster than a tool process's own lifetime for the normal-exit sweep to see
    /// it before it (and its intermediate parent) exit.
    public let snapshotInterval: Duration

    public init(
        gracePeriod: Duration = .seconds(3), pollInterval: Duration = .milliseconds(20),
        snapshotInterval: Duration = .milliseconds(100)
    ) {
        self.gracePeriod = gracePeriod
        self.pollInterval = pollInterval
        self.snapshotInterval = snapshotInterval
    }

    public func run(_ launch: AgentCLILaunch) async throws(AgentCLILaunchError) -> AgentCLIRunReport {
        let execution = try await execute(launch)
        let outcome = RunOutcome.classify(end: execution.end, resultFileAt: launch.resultFile, pass: launch.pass)
        return AgentCLIRunReport(
            pid: execution.pid, processGroup: execution.processGroup, end: execution.end, outcome: outcome,
            leftovers: execution.leftovers, snapshot: execution.snapshot
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

        // Captured before the spawn, so every process the run starts is strictly later (rule 2 of the
        // attributed fence compares against this).
        var dispatchedAtTV = timeval()
        gettimeofday(&dispatchedAtTV, nil)
        let dispatchedAt = ProcessStartTime(
            seconds: UInt64(dispatchedAtTV.tv_sec), microseconds: UInt64(dispatchedAtTV.tv_usec)
        )
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

        let result = await self.wait(pid: pid, timeout: launch.timeout, dispatchedAt: dispatchedAt)
        return AgentCLIExecution(
            pid: pid, processGroup: pid, end: result.end, leftovers: result.leftovers, snapshot: result.snapshot
        )
    }

    // MARK: - Waiting

    /// How ``wait(pid:timeout:dispatchedAt:)`` ended: the run's ending, what a normal exit swept, and
    /// the running snapshot.
    private struct WaitResult {
        let end: RunEnd
        let leftovers: [LeftoverProcess]
        let snapshot: RunningSnapshot
    }

    /// Polls `waitpid(WNOHANG)` in the calling task (never a detached one) so `Task.isCancelled`
    /// stays observable, until the leader exits, the engine cancels, or `timeout` elapses. While
    /// the leader is alive, also re-walks its descendant tree every `snapshotInterval` (first walk
    /// on the very first poll), folding results into a cumulative `Set` — a union across walks, not
    /// "latest": a tool whose intermediate parent has already exited drops out of a later walk, but
    /// a stale entry in the snapshot is harmless, because every signal against it is re-checked by
    /// identity before it is sent. On a NORMAL exit, that snapshot is handed to
    /// ``sweepAfterExit(tracked:)`` — the only place a normal exit's leftovers can still be found,
    /// since macOS reparents children to `launchd` at exit, not at reap.
    private func wait(pid: pid_t, timeout: Duration, dispatchedAt: ProcessStartTime) async -> WaitResult {
        let clock = ContinuousClock()
        let start = clock.now
        var tracked = Set<ProcessTree.TrackedProcess>()
        var lastSnapshot: ContinuousClock.Instant?

        func snapshot() -> RunningSnapshot {
            Self.makeSnapshot(leaderPID: pid, dispatchedAt: dispatchedAt, tracked: tracked)
        }

        while true {
            if lastSnapshot == nil || clock.now - lastSnapshot! >= snapshotInterval {
                tracked.formUnion(ProcessTree.descendants(of: pid))
                lastSnapshot = clock.now
            }
            if let end = ProcessGroup.reapNonBlocking(pid: pid) {
                let leftovers = await sweepAfterExit(tracked: tracked)
                return WaitResult(end: end, leftovers: leftovers, snapshot: snapshot())
            }
            if Task.isCancelled {
                let end = await terminate(pid: pid, reason: .aborted)
                return WaitResult(end: end, leftovers: [], snapshot: snapshot())
            }
            if clock.now - start >= timeout {
                let end = await terminate(pid: pid, reason: .timedOut(after: timeout))
                return WaitResult(end: end, leftovers: [], snapshot: snapshot())
            }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// Builds the running snapshot from the cumulative descendant walk `wait` accumulated, plus
    /// the CLI leader's own process group. Each tracked process is re-identified fresh (`ProcessTree.identity`)
    /// the same way ``sortedLeftovers(_:)`` does — a stale `tracked` entry may carry an outdated
    /// process group or session (e.g. after `setsid()`), so both the recorded and the current
    /// group/session are folded into ``RunningSnapshot/processGroups``/``sessions`` when the
    /// process is still identifiable; an entry that has already exited keeps only what was
    /// recorded when it was last seen alive.
    static func makeSnapshot(
        leaderPID: pid_t, dispatchedAt: ProcessStartTime, tracked: Set<ProcessTree.TrackedProcess>
    ) -> RunningSnapshot {
        var processes: [SnapshotProcess] = []
        var groups = Set<pid_t>()
        var sessions = Set<pid_t>()

        func fold(_ tracked: ProcessTree.TrackedProcess) {
            let current = ProcessTree.identity(of: tracked.pid)
            let matchesTracked = current.map {
                $0.pid == tracked.pid && $0.startSeconds == tracked.startSeconds
                    && $0.startMicroseconds == tracked.startMicroseconds
            } ?? false
            processes.append(SnapshotProcess(
                pid: tracked.pid,
                startTime: ProcessStartTime(seconds: tracked.startSeconds, microseconds: tracked.startMicroseconds),
                processGroup: tracked.processGroup, session: tracked.session, commandName: tracked.commandName
            ))
            groups.insert(tracked.processGroup)
            sessions.insert(tracked.session)
            if matchesTracked, let current {
                groups.insert(current.processGroup)
                sessions.insert(current.session)
            }
        }

        // The leader itself is not re-read: on a normal exit it is already reaped, and its pid may
        // name another process by now. Its group is added by pid; its session is the engine's.
        for process in tracked {
            fold(process)
        }
        groups.insert(leaderPID)

        let engineGroup = getpgrp()
        let engineSession = getsid(0)
        groups = groups.filter { $0 > 1 && $0 != engineGroup }
        sessions = sessions.filter { $0 > 1 && $0 != engineSession }

        return RunningSnapshot(
            dispatchedAt: dispatchedAt, processes: processes, processGroups: groups, sessions: sessions
        )
    }

    /// Why a run is being ended by Yellowhammer rather than the CLI's own exit — shared with
    /// `AgentCLIProcess+Termination.swift`, where the actual signalling and reaping lives.
    enum TerminationReason {
        case timedOut(after: Duration)
        case aborted
    }
}
