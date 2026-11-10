import Foundation

/// Describes the CLI invocation to be executed by `PassWrapper` inside an Orca terminal tab
/// (ADR-007 items 4–6).
public struct PassWrapperSpec: Codable, Sendable, Equatable {
    /// The CLI's absolute path.
    public var executable: String
    /// The arguments passed to the CLI (`argv[1...]`, or `argv[0...]` if executable is included).
    public var argv: [String]
    /// The working directory for the CLI process (the Worktree).
    public var worktreePath: String
    /// Where stdout is captured (in addition to being teed to the wrapper's stdout / pty).
    public var stdoutCapturePath: String
    /// Where stderr is directed (`nil` or empty directs to `/dev/null`).
    public var stderrPath: String?
    /// Where `wrapper-started.json` is written atomically once the CLI has spawned.
    public var startedPath: String
    /// Where `wrapper-status.json` is written atomically once the CLI has ended.
    public var statusPath: String

    public init(
        executable: String,
        argv: [String],
        worktreePath: String,
        stdoutCapturePath: String,
        stderrPath: String? = nil,
        startedPath: String,
        statusPath: String
    ) {
        self.executable = executable
        self.argv = argv
        self.worktreePath = worktreePath
        self.stdoutCapturePath = stdoutCapturePath
        self.stderrPath = stderrPath
        self.startedPath = startedPath
        self.statusPath = statusPath
    }

    public init(
        launch: AgentCLILaunch,
        runDirectory: URL
    ) {
        self.executable = launch.executable
        self.argv = launch.arguments
        self.worktreePath = launch.worktreePath
        let stdout = launch.standardOutput ?? runDirectory.appendingPathComponent("stdout.log")
        self.stdoutCapturePath = stdout.path
        self.stderrPath = launch.outputLog?.path
        self.startedPath = runDirectory.appendingPathComponent(PassWrapper.startedFileName).path
        self.statusPath = runDirectory.appendingPathComponent(PassWrapper.statusFileName).path
    }

    enum CodingKeys: String, CodingKey {
        case executable
        case argv
        case arguments
        case worktreePath
        case worktree
        case stdoutCapturePath
        case capturePath
        case standardOutputPath
        case stderrPath
        case outputPath
        case outputLogPath
        case startedPath
        case startedRecordPath
        case statusPath
        case statusRecordPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.executable = try container.decode(String.self, forKey: .executable)

        if let argv = try container.decodeIfPresent([String].self, forKey: .argv) {
            self.argv = argv
        } else if let arguments = try container.decodeIfPresent([String].self, forKey: .arguments) {
            self.argv = arguments
        } else {
            self.argv = []
        }

        if let path = try container.decodeIfPresent(String.self, forKey: .worktreePath) {
            self.worktreePath = path
        } else {
            self.worktreePath = try container.decode(String.self, forKey: .worktree)
        }

        if let capture = try container.decodeIfPresent(String.self, forKey: .stdoutCapturePath) {
            self.stdoutCapturePath = capture
        } else if let capture = try container.decodeIfPresent(String.self, forKey: .capturePath) {
            self.stdoutCapturePath = capture
        } else {
            self.stdoutCapturePath = try container.decode(String.self, forKey: .standardOutputPath)
        }

        if let err = try container.decodeIfPresent(String.self, forKey: .stderrPath) {
            self.stderrPath = err
        } else if let err = try container.decodeIfPresent(String.self, forKey: .outputPath) {
            self.stderrPath = err
        } else {
            self.stderrPath = try container.decodeIfPresent(String.self, forKey: .outputLogPath)
        }

        if let started = try container.decodeIfPresent(String.self, forKey: .startedPath) {
            self.startedPath = started
        } else {
            self.startedPath = try container.decode(String.self, forKey: .startedRecordPath)
        }

        if let status = try container.decodeIfPresent(String.self, forKey: .statusPath) {
            self.statusPath = status
        } else {
            self.statusPath = try container.decode(String.self, forKey: .statusRecordPath)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(executable, forKey: .executable)
        try container.encode(argv, forKey: .argv)
        try container.encode(worktreePath, forKey: .worktreePath)
        try container.encode(stdoutCapturePath, forKey: .stdoutCapturePath)
        try container.encodeIfPresent(stderrPath, forKey: .stderrPath)
        try container.encode(startedPath, forKey: .startedPath)
        try container.encode(statusPath, forKey: .statusPath)
    }

    /// Writes this spec file to the given destination URL.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try PassWrapper.writeAtomic(data: data, to: url)
    }
}

/// The atomic start record written once the CLI process is running in its own session.
public struct PassWrapperStarted: Codable, Sendable, Equatable {
    public var pid: Int32
    public var processGroup: Int32
    public var session: Int32
    public var startSeconds: UInt64
    public var startMicroseconds: UInt64

    public init(
        pid: Int32,
        processGroup: Int32,
        session: Int32,
        startSeconds: UInt64,
        startMicroseconds: UInt64
    ) {
        self.pid = pid
        self.processGroup = processGroup
        self.session = session
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
    }
}

/// The atomic status record written once the CLI process has ended.
public struct PassWrapperStatus: Codable, Sendable, Equatable {
    public var exitStatus: Int32?
    public var signal: Int32?
    public var receivedSignals: [Int32]

    public init(
        exitStatus: Int32? = nil,
        signal: Int32? = nil,
        receivedSignals: [Int32] = []
    ) {
        self.exitStatus = exitStatus
        self.signal = signal
        self.receivedSignals = receivedSignals
    }
}
