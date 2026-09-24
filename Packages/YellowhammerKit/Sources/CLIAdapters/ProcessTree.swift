import Darwin
import Foundation

/// `libproc` glue for walking a process's live descendant tree, in the style of
/// ``ProcessGroup``. `AgentCLIProcess`'s termination sweep needs this because a real agent CLI's
/// tool commands escape the CLI's process group on purpose (claude's Bash tool calls `setsid`;
/// codex makes the tool command itself a new group leader) — a plain `kill(-pgid, _)` never
/// reaches them. `setsid` does not change `ppid`, though, so the escaped tool stays a direct
/// child of the CLI while the CLI is alive; walking the descendant tree finds it.
enum ProcessTree {
    /// One process observed at a point in time: its pid, its process group (recorded for
    /// reporting only — see ``signal(_:_:)``), and its start time, which stands in for identity.
    struct TrackedProcess: Hashable, Sendable {
        let pid: pid_t
        let processGroup: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    /// Looks up `pid`'s current identity, or `nil` if the call fails or the process is a zombie
    /// (`SZOMB`) — a zombie is already dead in every sense that matters here, just not yet reaped.
    static func identity(of pid: pid_t) -> TrackedProcess? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard result == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        return TrackedProcess(
            pid: pid,
            processGroup: pid_t(bitPattern: info.pbi_pgid),
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    /// Every live descendant of `root`, found by walking `proc_listchildpids` breadth-first from
    /// `root`. Tolerates a process vanishing mid-walk (it is simply skipped, along with whatever
    /// subtree it might have had) and never visits the same pid twice.
    static func descendants(of root: pid_t) -> [TrackedProcess] {
        var result: [TrackedProcess] = []
        var visited = Set<pid_t>()
        var frontier = childPIDs(of: root)

        while !frontier.isEmpty {
            var nextFrontier: [pid_t] = []
            for pid in frontier where !visited.contains(pid) {
                visited.insert(pid)
                guard let tracked = identity(of: pid) else { continue }
                result.append(tracked)
                nextFrontier.append(contentsOf: childPIDs(of: pid))
            }
            frontier = nextFrontier
        }
        return result
    }

    /// Every ancestor of `pid`, walking `pbi_ppid` upward: starts with `pid`'s own parent and
    /// continues through each ancestor's parent in turn, stopping once pid 1 (`launchd`) is
    /// reached (included in the result), pid 0 is reached, or a lookup fails (a process that has
    /// already exited yields whatever prefix of the chain was still readable). Capped at 64 hops
    /// so a corrupt or unexpected parent chain can never spin forever.
    static func ancestors(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var current = pid
        for _ in 0..<64 {
            guard let parent = parentPID(of: current) else { break }
            result.append(parent)
            if parent <= 1 { break }
            current = parent
        }
        return result
    }

    /// `pid`'s parent, or `nil` if the lookup fails (the process has already exited).
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard result == size else { return nil }
        return pid_t(bitPattern: info.pbi_ppid)
    }

    /// Whether `process` is gone: its identity can no longer be looked up, or the pid now
    /// belongs to a different process (a mismatched start time). The latter is pid reuse, not
    /// survival — the process this `TrackedProcess` named has already exited.
    static func isGone(_ process: TrackedProcess) -> Bool {
        guard let current = identity(of: process.pid) else { return true }
        return !sameProcess(current, process)
    }

    /// Signals `process` only after re-confirming, right now, that its pid still names the same
    /// process (matching start time) — never its process group. A tool that calls `setsid()`
    /// during the grace window changes its pgid but not its start time, so checking pgid instead
    /// would let exactly that escape re-open here. Returns whether a signal was actually sent.
    @discardableResult
    static func signal(_ process: TrackedProcess, _ signal: Int32) -> Bool {
        guard let current = identity(of: process.pid), sameProcess(current, process) else { return false }
        return kill(process.pid, signal) == 0
    }

    private static func sameProcess(_ lhs: TrackedProcess, _ rhs: TrackedProcess) -> Bool {
        lhs.startSeconds == rhs.startSeconds && lhs.startMicroseconds == rhs.startMicroseconds
    }

    /// The live child pids of `ppid`. `proc_listchildpids`'s return value is a count of pids, not
    /// bytes (unlike most other `libproc` calls); when the buffer comes back full, this doubles
    /// the buffer and retries, up to a generous cap, rather than silently truncating the list.
    private static func childPIDs(of ppid: pid_t) -> [pid_t] {
        var capacity = 64
        let maxCapacity = 1 << 16

        while capacity <= maxCapacity {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bufferSize = Int32(capacity * MemoryLayout<pid_t>.size)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listchildpids(ppid, buffer.baseAddress, bufferSize)
            }
            guard count >= 0 else { return [] }
            if Int(count) < capacity {
                return Array(pids.prefix(Int(count)))
            }
            capacity *= 2
        }
        return []
    }
}
