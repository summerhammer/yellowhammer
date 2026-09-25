import Foundation

/// Wall-clock time in the same terms `proc_bsdinfo.pbi_start_tvsec`/`pbi_start_tvusec` report a
/// process's start: seconds and microseconds since the epoch, as `gettimeofday` returns them —
/// never `ContinuousClock`, which has no relationship to those kernel fields.
public struct ProcessStartTime: Equatable, Hashable, Comparable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public static func < (lhs: ProcessStartTime, rhs: ProcessStartTime) -> Bool {
        (lhs.seconds, lhs.microseconds) < (rhs.seconds, rhs.microseconds)
    }
}

/// One process the running snapshot observed: its identity (pid plus start time) and the
/// process-group/session/command-name it carried at the moment it was recorded. Reporting-only
/// fields, the same way ``ProcessTree/TrackedProcess`` treats them — a process that changes group
/// or session after being recorded is still the same process for attribution purposes.
public struct SnapshotProcess: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let startTime: ProcessStartTime
    public let processGroup: pid_t
    public let session: pid_t
    public let commandName: String

    public init(pid: pid_t, startTime: ProcessStartTime, processGroup: pid_t, session: pid_t, commandName: String) {
        self.pid = pid
        self.startTime = startTime
        self.processGroup = processGroup
        self.session = session
        self.commandName = commandName
    }
}

/// The running descendant snapshot one agent CLI run took while its leader was alive — the
/// evidence the Normal-Exit Sweep Ruling's attributed Worktree fence needs to tell a process this
/// run spawned apart from an unrelated one that merely happens to be inside the same Worktree
/// (issue #175). Shaped so it could later be persisted to the Journal (OQ91(c)); this slice does
/// not persist it.
///
/// `processGroups` and `sessions` are `Set<pid_t>` on purpose, not the finer-grained
/// `SnapshotProcess` list: the fence's attribution rule 2 only needs membership, and pgid/session
/// values are cheap and stable to compare against, unlike full process identity. Both sets
/// deliberately exclude the engine's own process group and session — the CLI leader shares yh's
/// session (`posix_spawn` does not create a new one), and letting that session attribute an
/// unrelated process would be a false positive with no bound.
public struct RunningSnapshot: Equatable, Sendable {
    /// The wall-clock time this run was spawned, captured with `gettimeofday` immediately before
    /// the spawn call — compared against ``SnapshotProcess/startTime`` (also wall-clock), never a
    /// monotonic clock.
    public let dispatchedAt: ProcessStartTime
    /// Every process the cumulative descendant snapshot ever saw while the leader was alive,
    /// sorted by pid for determinism.
    public let processes: [SnapshotProcess]
    /// Every process group seen in the snapshot, plus the CLI leader's own group (the leader is
    /// its own process group's founder; `descendants(of:)`-style walks exclude the root, so it is
    /// added explicitly here), minus the engine's own process group.
    public let processGroups: Set<pid_t>
    /// Every session seen in the snapshot, plus the CLI leader's own session, minus the engine's
    /// own session.
    public let sessions: Set<pid_t>

    public init(
        dispatchedAt: ProcessStartTime, processes: [SnapshotProcess], processGroups: Set<pid_t>,
        sessions: Set<pid_t>
    ) {
        self.dispatchedAt = dispatchedAt
        self.processes = processes.sorted { $0.pid < $1.pid }
        self.processGroups = processGroups
        self.sessions = sessions
    }
}
