import Darwin
import Domain
import Foundation

/// `libproc` glue for reading one process's identity: pid, parent, process group, session, start
/// time, and command name. Modelled on `CLIAdapters/ProcessTree.identity(of:)` — duplicated here
/// rather than shared, because `Repositories` must not import `CLIAdapters` (module boundary,
/// ADR-001: a Port's implementation lives above another module, never crosses sideways).
enum ProcessIdentity {
    /// One process observed right now. Identity for attribution purposes is `pid` plus
    /// `startTime` — the same convention `ProcessTree.TrackedProcess` and `Domain.SnapshotProcess`
    /// use.
    struct Snapshot: Equatable {
        let pid: pid_t
        let parentPID: pid_t
        let processGroup: pid_t
        let session: pid_t
        let startTime: ProcessStartTime
        let commandName: String
    }

    /// Looks up `pid`'s current identity, or `nil` if the call fails or the process is a zombie
    /// (`SZOMB`) — already dead in every sense that matters here, just not yet reaped.
    static func identity(of pid: pid_t) -> Snapshot? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        guard result == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        return Snapshot(
            pid: pid,
            parentPID: pid_t(bitPattern: info.pbi_ppid),
            processGroup: pid_t(bitPattern: info.pbi_pgid),
            session: getsid(pid),
            startTime: ProcessStartTime(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec),
            commandName: commandName(from: info)
        )
    }

    /// `pbi_name` when the process registered one, else `pbi_comm` — both fixed-size C char
    /// arrays, read up to the first NUL but never past the array, since a name filling the whole
    /// array carries no terminator.
    private static func commandName(from info: proc_bsdinfo) -> String {
        func decode(_ bytes: UnsafeRawBufferPointer) -> String {
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
        let name = withUnsafeBytes(of: info.pbi_name, decode)
        return name.isEmpty ? withUnsafeBytes(of: info.pbi_comm, decode) : name
    }

    /// Walks `pid`'s ancestor chain via `pbi_ppid`, starting with its own identity and continuing
    /// through each ancestor's parent in turn, stopping at pid 1 (`launchd`, included), pid 0, a
    /// lookup failure (the parent has already exited — expected, not a bug), or 64 hops.
    static func chain(from pid: pid_t) -> [Snapshot] {
        var result: [Snapshot] = []
        guard var current = identity(of: pid) else { return [] }
        result.append(current)
        for _ in 0..<64 {
            guard current.parentPID > 0 else { break }
            guard let parent = identity(of: current.parentPID) else { break }
            result.append(parent)
            if parent.pid <= 1 { break }
            current = parent
        }
        return result
    }
}
