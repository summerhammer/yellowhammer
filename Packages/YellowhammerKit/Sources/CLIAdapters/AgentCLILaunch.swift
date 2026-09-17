import Domain
import Foundation

/// Everything the process lifecycle needs to run one agent CLI pass. A CLI adapter (P7.3) builds
/// it from a Route and a Worktree; this module only executes it.
public struct AgentCLILaunch: Sendable {
    /// The CLI's absolute path. Spawned directly, never via `posix_spawnp`'s `PATH` search.
    public var executable: String
    /// `argv[1...]`; `argv[0]` is `executable`.
    public var arguments: [String]
    public var environment: [String: String]
    /// The process's cwd. Must exist as a directory — checked before spawning.
    public var worktreePath: String
    /// Where the CLI is told to write its result file, and where the dual-key check reads it back.
    public var resultFile: URL
    public var pass: RunPass
    /// SIGTERM-to-the-group deadline. Escalates to SIGKILL after the runner's grace period.
    public var timeout: Duration
    /// Stdout and stderr are appended here. `nil` discards both to `/dev/null`.
    public var outputLog: URL?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        worktreePath: String,
        resultFile: URL,
        pass: RunPass,
        timeout: Duration,
        outputLog: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.worktreePath = worktreePath
        self.resultFile = resultFile
        self.pass = pass
        self.timeout = timeout
        self.outputLog = outputLog
    }
}
