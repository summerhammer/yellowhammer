import Darwin
import Foundation

/// A child process spawned with `posix_spawn`, used in place of Foundation `Process` in the
/// `ProcessFencer` tests. `Process.waitUntilExit()` intermittently never returned after
/// `ProcessFencer` SIGKILLed the child: the child was already dead and reaped, but Foundation
/// never flipped `isRunning`, so the test thread spun its run loop forever.
final class SpawnedChild: @unchecked Sendable {
    enum ExitStatus: Equatable {
        case exited(Int32)
        case signalled(Int32)
        case alreadyReaped
    }

    enum SpawnError: Error {
        case spawnFailed(Int32)
    }

    let pid: pid_t
    private let isGroupLeader: Bool

    private let lock = NSLock()
    private var reapedStatus: ExitStatus?

    private init(pid: pid_t, isGroupLeader: Bool) {
        self.pid = pid
        self.isGroupLeader = isGroupLeader
    }

    static func spawn(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        newProcessGroup: Bool = false
    ) throws -> SpawnedChild {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addchdir(&fileActions, currentDirectory.path)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        if newProcessGroup {
            posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attr, 0)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable)]
        argv.append(contentsOf: arguments.map { strdup($0) })
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, &argv, &envp)
        guard rc == 0 else { throw SpawnError.spawnFailed(rc) }
        return SpawnedChild(pid: pid, isGroupLeader: newProcessGroup)
    }

    private func decode(_ status: Int32) -> ExitStatus {
        let signalled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        if signalled {
            return .signalled(status & 0x7f)
        }
        return .exited((status >> 8) & 0xff)
    }

    /// Non-blocking: reaps (and caches) the exit status if the child has already exited.
    private func pollOnce() -> ExitStatus? {
        lock.withLock {
            if let reapedStatus { return reapedStatus }
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                let decoded = decode(status)
                reapedStatus = decoded
                return decoded
            } else if result == -1 && errno == ECHILD {
                reapedStatus = .alreadyReaped
                return .alreadyReaped
            }
            return nil
        }
    }

    var isRunning: Bool {
        pollOnce() == nil
    }

    func waitForExit(timeout: Duration = .seconds(10)) async -> ExitStatus? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let status = pollOnce() {
                return status
            }
            if ContinuousClock.now >= deadline {
                return nil
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Synchronous, bounded cleanup suitable for a `defer`. Kills the child (or its whole
    /// process group, if it is a group leader) and reaps it with a short polling loop —
    /// never an unbounded `waitpid(..., 0)`.
    func terminateAndReap() {
        if isGroupLeader {
            // Always signal the group, even if the leader itself already exited: a
            // backgrounded sibling (e.g. the shell's `sleep 300 &`) can still be alive.
            kill(-pid, SIGKILL)
        } else if isRunning {
            kill(pid, SIGKILL)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while pollOnce() == nil && ContinuousClock.now < deadline {
            usleep(20_000)
        }
    }
}
