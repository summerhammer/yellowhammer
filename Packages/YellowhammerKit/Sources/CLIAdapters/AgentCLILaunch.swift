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
    /// Stderr is appended here (and stdout too, when ``standardOutput`` is `nil`). `nil` discards to
    /// `/dev/null`.
    public var outputLog: URL?
    /// When set, stdout is appended here instead of ``outputLog`` (P7.3: a CLI Adapter reads its
    /// CLI's structured stdout separately from its diagnostic stderr). `nil` keeps the original
    /// behavior — both streams share ``outputLog``.
    public var standardOutput: URL?

    public init(
        executable: String,
        arguments: [String],
        environment: [String: String],
        worktreePath: String,
        resultFile: URL,
        pass: RunPass,
        timeout: Duration,
        outputLog: URL? = nil,
        standardOutput: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.worktreePath = worktreePath
        self.resultFile = resultFile
        self.pass = pass
        self.timeout = timeout
        self.outputLog = outputLog
        self.standardOutput = standardOutput
    }
}
