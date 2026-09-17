import Darwin
import Foundation

/// One process found holding a Worktree: its current working directory is inside the
/// Worktree's path, or it has a file inside the Worktree open.
public struct WorktreeHolder: Hashable, Sendable {
    public let pid: pid_t
    public let reason: Reason

    public init(pid: pid_t, reason: Reason) {
        self.pid = pid
        self.reason = reason
    }

    public enum Reason: Hashable, Sendable {
        /// The process's current working directory is inside the Worktree.
        case workingDirectory(String)
        /// The process holds an open file descriptor on a path inside the Worktree.
        case openFile(String)
    }
}

/// The outcome of fencing a Worktree before reconciliation touches it.
public enum FencingOutcome: Equatable, Sendable {
    /// The Worktree's path is quiescent (no process holds it). `killed` lists every process that
    /// was sent `SIGKILL` to get there; empty when nothing was holding the path to begin with.
    case quiescent(killed: [WorktreeHolder])
    /// Holders remained after `ProcessFencer.quiescenceTimeout` elapsed. `remaining` lists them.
    case notQuiescent(killed: [WorktreeHolder], remaining: [WorktreeHolder])
    /// The Worktree's path does not exist; there was nothing to sweep.
    case pathMissing(String)
}

/// Sweeps the host process table for every process fenced to a Worktree's path, before
/// reconciliation inspects uncommitted edits, creates a WIP commit, resets a Worktree, or an
/// expired Lease is reclaimed (spec `loop-state/reconcile-worktrees-at-act-start`,
/// `loop-state/reclaim-an-expired-lease`).
///
/// A killed agent CLI can orphan tool subprocesses that keep writing in the Worktree after the
/// Act that spawned them is gone (feasibility probe finding, OQ57). Those subprocesses are never
/// asked to stop cooperatively: every holder is terminated immediately with `SIGKILL`, and
/// reconciliation pauses until the path is strictly quiescent — zero processes hold it — before
/// any WIP commit or reset proceeds.
///
/// This is local process-table work, like local git: not behind a Port, a concrete
/// Yellowhammer-owned type using Apple's `libproc` directly, never shelling out to `lsof`.
public struct ProcessFencer: Sendable {
    /// How often `fence(worktreePath:)` re-checks the process table while waiting for quiescence.
    public let pollInterval: Duration
    /// How long `fence(worktreePath:)` waits for quiescence before giving up.
    public let quiescenceTimeout: Duration

    public init(pollInterval: Duration = .milliseconds(50), quiescenceTimeout: Duration = .seconds(10)) {
        self.pollInterval = pollInterval
        self.quiescenceTimeout = quiescenceTimeout
    }

    /// Every process whose current working directory or an open file lies inside
    /// `worktreePath` (resolved), excluding this process itself.
    public func holders(of worktreePath: String) -> [WorktreeHolder] {
        let resolvedWorktreePath = Self.resolve(worktreePath)
        let thisProcess = getpid()
        var found: [WorktreeHolder] = []

        for pid in Self.listAllPIDs() where pid != thisProcess {
            if let cwd = Self.currentWorkingDirectory(of: pid), Self.isInside(cwd, of: resolvedWorktreePath) {
                found.append(WorktreeHolder(pid: pid, reason: .workingDirectory(cwd)))
            }
            for openPath in Self.openVnodePaths(of: pid) where Self.isInside(openPath, of: resolvedWorktreePath) {
                found.append(WorktreeHolder(pid: pid, reason: .openFile(openPath)))
            }
        }
        return found
    }

    /// Kills every holder of `worktreePath` with `SIGKILL`, then polls until none remain or
    /// `quiescenceTimeout` elapses. A holder that appears during the wait is killed too and
    /// folded into the returned `killed` list.
    public func fence(worktreePath: String) async -> FencingOutcome {
        let resolvedWorktreePath = Self.resolve(worktreePath)
        guard FileManager.default.fileExists(atPath: resolvedWorktreePath) else {
            return .pathMissing(resolvedWorktreePath)
        }

        var killed: [WorktreeHolder] = []
        var killedPIDs = Set<pid_t>()

        func killNewHolders(_ found: [WorktreeHolder]) {
            for holder in found where !killedPIDs.contains(holder.pid) {
                kill(holder.pid, SIGKILL)
                killedPIDs.insert(holder.pid)
                killed.append(holder)
            }
        }

        killNewHolders(holders(of: resolvedWorktreePath))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: quiescenceTimeout)
        while clock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            let found = holders(of: resolvedWorktreePath)
            if found.isEmpty {
                return .quiescent(killed: killed)
            }
            killNewHolders(found)
        }

        let remaining = holders(of: resolvedWorktreePath)
        guard remaining.isEmpty else {
            return .notQuiescent(killed: killed, remaining: remaining)
        }
        return .quiescent(killed: killed)
    }

    // MARK: - Path resolution

    /// Resolves `path` to the real filesystem path `libproc` reports, so a Worktree under
    /// `/var/...` (or `/tmp/...`) compares equal to the `/private/var/...` (or `/private/tmp/...`)
    /// path the kernel hands back for a process's cwd or open files.
    ///
    /// Deliberately calls libc `realpath(3)` rather than `URL.resolvingSymlinksInPath()`:
    /// Foundation's resolver leaves `/tmp`, `/var` and `/etc` unresolved for compatibility, which
    /// would silently defeat this comparison for exactly the paths `FileManager.temporaryDirectory`
    /// hands out.
    private static func resolve(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(expanded, &buffer) else { return expanded }
        return String(cString: resolved)
    }

    /// `candidate` is inside `resolvedWorktreePath` when it equals it exactly or has it plus a
    /// path separator as a prefix, so `/x/wt2` never matches a Worktree at `/x/wt`.
    private static func isInside(_ candidate: String, of resolvedWorktreePath: String) -> Bool {
        candidate == resolvedWorktreePath || candidate.hasPrefix(resolvedWorktreePath + "/")
    }

    // MARK: - libproc

    private static func listAllPIDs() -> [pid_t] {
        let initialCount = proc_listallpids(nil, 0)
        guard initialCount > 0 else { return [] }

        // Headroom: processes may be created between the sizing call and the fetch below.
        let capacity = Int(initialCount) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bufferSize = Int32(capacity * MemoryLayout<pid_t>.size)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, bufferSize)
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// The process's current working directory, or `nil` if it has exited, is a zombie, or the
    /// query is otherwise refused (e.g. permission) — such a pid simply is not a holder.
    private static func currentWorkingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, size)
        }
        guard result == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// Every path the process has open on a vnode (a real file or directory, not a socket, pipe
    /// or similar). A pid that has exited between listing and this query yields no paths.
    private static func openVnodePaths(of pid: pid_t) -> [String] {
        let sizeInBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard sizeInBytes > 0 else { return [] }

        // Headroom: fds may open between the sizing call and the fetch below.
        let capacity = Int(sizeInBytes) / MemoryLayout<proc_fdinfo>.size + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let bufferSize = Int32(capacity * MemoryLayout<proc_fdinfo>.size)
        let written = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, bufferSize)
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<proc_fdinfo>.size

        var paths: [String] = []
        for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnodeInfo = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            let result = withUnsafeMutablePointer(to: &vnodeInfo) { pointer in
                proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, pointer, vnodeSize)
            }
            guard result == vnodeSize else { continue }
            let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if !path.isEmpty {
                paths.append(path)
            }
        }
        return paths
    }
}
