import Darwin
import Domain
import Foundation

/// POSIX process-group glue for ``AgentCLIProcess``: spawn a child as the leader of its own new
/// process group, signal or probe that group, and reap the leader. Kept separate so
/// `AgentCLIProcess` reads as the run lifecycle, not libc plumbing.
enum ProcessGroup {
    /// The result of one `posix_spawn` attempt: the child's pid, or the `errno`-style return code.
    enum SpawnOutcome {
        case success(pid_t)
        case failure(Int32)
    }

    /// Spawns `executable` (by absolute path — `posix_spawn`, not `posix_spawnp`) with `arguments`
    /// and `environment`, chdir'd to `worktreePath`, as the leader of a new process group whose
    /// pgid equals its own pid. Stdin is `/dev/null` (closed to input); stdout and stderr each
    /// append to `outputPath`, or `/dev/null` when `outputPath` is `nil`.
    static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String],
        worktreePath: String,
        outputPath: String?
    ) -> SpawnOutcome {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let output = outputPath ?? "/dev/null"
        posix_spawn_file_actions_addchdir(&fileActions, worktreePath)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_addopen(&fileActions, 2, output, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        // Reset every signal disposition to default, and unblock every signal, in the child.
        // Without this, a signal the calling process (e.g. a test host, or Yellowhammer itself)
        // has set to SIG_IGN or blocked in its mask would still be ignored or pending-forever
        // after `exec`, silently defeating `SIGTERM`/`SIGKILL` delivery below.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        let argv = cStringArray([executable] + arguments)
        let envp = cStringArray(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
        guard rc == 0 else { return .failure(rc) }
        return .success(pid)
    }

    /// Sends `signal` to every process in `pgid`'s process group.
    static func signal(group pgid: pid_t, _ signal: Int32) {
        kill(-pgid, signal)
    }

    /// Whether any process remains in `pgid`'s process group — `kill(-pgid, 0)` succeeds.
    static func isAlive(group pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0
    }

    /// Non-blocking reap of the leader `pid`. `nil` while it is still running.
    static func reapNonBlocking(pid: pid_t) -> RunEnd? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return nil }
        return runEnd(fromStatus: status)
    }

    /// Blocking reap of the leader `pid`.
    @discardableResult
    static func reapBlocking(pid: pid_t) -> RunEnd? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, 0)
        guard result == pid else { return nil }
        return runEnd(fromStatus: status)
    }

    /// Decodes a `waitpid` status into a ``RunEnd``. The `W*` macros are not imported into Swift,
    /// so this uses the same bit arithmetic they expand to: the low 7 bits are the terminating
    /// signal (0 means "exited normally"), and bits 8–15 are the exit code.
    private static func runEnd(fromStatus status: Int32) -> RunEnd {
        let terminatingSignal = status & 0x7f
        if terminatingSignal == 0 {
            return .exited(status: (status >> 8) & 0xff)
        }
        return .signaled(terminatingSignal)
    }

    // MARK: - C string arrays

    /// A NULL-terminated `argv`/`envp`-shaped array of `strdup`'d C strings. Free with
    /// ``freeCStringArray(_:)`` once the synchronous `posix_spawn` call that used it returns.
    private static func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var array = strings.map { strdup($0) }
        array.append(nil)
        return array
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array {
            free(pointer)
        }
    }
}
