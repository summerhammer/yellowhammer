import Domain
import Foundation

/// An opaque conversational session/thread id one agent CLI hands back, so a later Round on the
/// same worker can resume it. Yellowhammer never parses it (spec: `routing/add-an-agent-cli` — a
/// CLI Adapter owns session resumption; the id's shape is the vendor's).
public struct CLISession: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension CLISession: CustomStringConvertible {
    public var description: String { rawValue }
}

/// Everything one CLI Adapter needs to build and run a single agent CLI pass, already resolved by
/// its caller — a Route's `cli`, `model` and `effort` are free strings until an adapter validates
/// them (spec: `routing/add-an-agent-cli`).
public struct CLIDispatch: Sendable {
    public var route: Route
    public var pass: RunPass
    /// The already-rendered prompt; the adapter neither composes nor edits it.
    public var instruction: String
    public var worktreePath: String
    /// A Yellowhammer-owned scratch directory for this one run: the adapter places `result.json`,
    /// its raw stdout/stderr capture and, for CLIs that need one, a schema file here.
    public var runDirectory: URL
    public var timeout: Duration
    /// Non-nil when this run is a Round on the same worker: the adapter resumes this session
    /// instead of starting a fresh one.
    public var resume: CLISession?
    /// Extra directories the CLI must be able to read beyond the Worktree.
    public var additionalReadableDirectories: [String]
    /// Extra directories the CLI must be able to write to beyond the Worktree — e.g. a linked
    /// Worktree's git common dir, so the worker can commit.
    public var additionalWritableDirectories: [String]
    /// The CLI's absolute path, already resolved by the caller from `CLIAdapterDeclaration.executable`.
    public var executable: String
    public var environment: [String: String]

    public init(
        route: Route,
        pass: RunPass,
        instruction: String,
        worktreePath: String,
        runDirectory: URL,
        timeout: Duration,
        resume: CLISession? = nil,
        additionalReadableDirectories: [String] = [],
        additionalWritableDirectories: [String] = [],
        executable: String,
        environment: [String: String] = [:]
    ) {
        self.route = route
        self.pass = pass
        self.instruction = instruction
        self.worktreePath = worktreePath
        self.runDirectory = runDirectory
        self.timeout = timeout
        self.resume = resume
        self.additionalReadableDirectories = additionalReadableDirectories
        self.additionalWritableDirectories = additionalWritableDirectories
        self.executable = executable
        self.environment = environment
    }
}

/// Why a CLI Adapter refused to build a launch for a dispatch.
public enum CLIAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The Route names another CLI; this adapter refuses rather than silently running under the
    /// wrong identity.
    case routeForOtherCLI(expected: String, got: String)
    /// The Route's effort is not one this CLI accepts.
    case unsupportedEffort(cli: String, effort: String, supported: [String])
    /// `runDirectory` could not be created or written to.
    case runDirectoryUnwritable(String)

    public var description: String {
        switch self {
        case .routeForOtherCLI(let expected, let got):
            "route names CLI `\(got)`, but this is the `\(expected)` adapter"
        case .unsupportedEffort(let cli, let effort, let supported):
            "\(cli) does not support effort `\(effort)` (supported: \(supported.joined(separator: ", ")))"
        case .runDirectoryUnwritable(let reason):
            "run directory unwritable: \(reason)"
        }
    }
}

/// The code that owns one agent CLI's argv shape, session resumption, structured-output reading
/// and model/effort mapping (glossary: CLI Adapter; spec `routing/add-an-agent-cli`). An adapter
/// translates; it never decides — the Route it is handed is built above it.
public protocol CLIAdapter: Sendable {
    /// The Routing Table's `cli` name, e.g. `"claude"`.
    var cli: String { get }
    /// This adapter's own version, independent of the CLI it drives — bumped when its argv shape,
    /// session handling or output-format assumptions change (P7.4: the Probe reports it alongside
    /// the CLI version, so drift is attributable to either side).
    var adapterVersion: String { get }
    /// Efforts this CLI accepts; a Route with another effort is refused at launch build time.
    var supportedEfforts: [String] { get }
    /// Builds the process launch for `dispatch`. Deletes any stale result file in `runDirectory`
    /// first, so an old file can never satisfy the dual-key completion check.
    func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch
    /// Called after the process ended, before the dual-key check. Reads stdout, materializes the
    /// result file if this CLI does not write it itself, and extracts the session to resume next.
    /// Never throws: a stdout Yellowhammer cannot parse just means no session is offered.
    func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession?
}

extension CLIAdapter {
    /// Shared refusal: every adapter validates the Route names it and accepts its effort before
    /// building a launch.
    func validateRoute(_ dispatch: CLIDispatch) throws(CLIAdapterError) {
        guard dispatch.route.cli == cli else {
            throw .routeForOtherCLI(expected: cli, got: dispatch.route.cli)
        }
        guard supportedEfforts.contains(dispatch.route.effort) else {
            throw .unsupportedEffort(cli: cli, effort: dispatch.route.effort, supported: supportedEfforts)
        }
    }

    /// Creates `runDirectory` if needed and removes any stale `result.json` inside it, so a leftover
    /// file from a previous run can never satisfy the dual-key completion check.
    func prepareRunDirectory(_ dispatch: CLIDispatch) throws(CLIAdapterError) -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: dispatch.runDirectory, withIntermediateDirectories: true)
        } catch {
            throw .runDirectoryUnwritable("\(error)")
        }
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        try? fileManager.removeItem(at: resultFile)
        return resultFile
    }
}
