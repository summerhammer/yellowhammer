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
    /// Absolute directories no pass may read: Yellowhammer's configuration directory (config, run
    /// artifacts, the Journals and their backups) and the login Keychains directory. An adapter that can
    /// contain its CLI uses them to deny reads; empty means nothing is denied (issue #546).
    public var protectedDirectories: [String]
    /// The CLI's absolute path, already resolved by the caller from `CLIAdapterDeclaration.executable`.
    public var executable: String
    public var environment: [String: String]
    public var provenance: DispatchProvenance?
    /// The Project instructions revision composed into `instruction`, or their absence; recorded with the
    /// dispatch's prompt record.
    public var projectInstructions: ProjectInstructionsUse

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
        protectedDirectories: [String] = [],
        executable: String,
        environment: [String: String] = [:],
        provenance: DispatchProvenance? = nil,
        projectInstructions: ProjectInstructionsUse = .absent
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
        self.protectedDirectories = protectedDirectories
        self.executable = executable
        self.environment = environment
        self.provenance = provenance
        self.projectInstructions = projectInstructions
    }
}

/// Why a CLI Adapter refused to build a launch for a dispatch.
public enum CLIAdapterError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The Route names another CLI; this adapter refuses rather than silently running under the
    /// wrong identity.
    case routeForOtherCLI(expected: String, got: String)
    /// The Route's effort is not one this CLI accepts.
    case unsupportedEffort(cli: String, effort: String, supported: [String])
    /// The Route's model id encodes an effort tier that disagrees with the Route's effort, which the CLI
    /// refuses at argument parsing (``RegisteredCLIAdapters/conflictingEffortSuffix(in:)``).
    case conflictingModelEffort(cli: String, model: String, effort: String)
    /// `runDirectory` could not be created or written to.
    case runDirectoryUnwritable(String)

    public var description: String {
        switch self {
        case .routeForOtherCLI(let expected, let got):
            "route names CLI `\(got)`, but this is the `\(expected)` adapter"
        case .unsupportedEffort(let cli, let effort, let supported):
            "\(cli) does not support effort `\(effort)` (supported: \(supported.joined(separator: ", ")))"
        case .conflictingModelEffort(let cli, let model, let effort):
            "\(cli) model `\(model)` already names an effort tier, which conflicts with effort `\(effort)`; "
                + "use a model whose suffix matches, or an unsuffixed model"
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
    /// Returns the structured-output schema JSON string passed to the CLI for this pass.
    func outputSchema(for pass: RunPass) -> String
    /// Builds the process launch for `dispatch`. Deletes any stale result file in `runDirectory`
    /// first, so an old file can never satisfy the dual-key completion check.
    func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch
    /// Called after the process ended, before the dual-key check. Reads stdout, materializes the
    /// result file if this CLI does not write it itself, and extracts the session to resume next.
    /// Never throws: a stdout Yellowhammer cannot parse just means no session is offered.
    func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession?
    /// Translates a recognized vendor usage-limit refusal from captured stdout. Called only for a
    /// non-zero self-exit. Unknown payloads return nil, preserving ordinary exit classification.
    func usageLimit(for dispatch: CLIDispatch) -> RunOutcome?
}

extension CLIAdapter {
    public func usageLimit(for dispatch: CLIDispatch) -> RunOutcome? { nil }

    /// Shared refusal: every adapter validates the Route names it and accepts its effort before
    /// building a launch.
    func validateRoute(_ dispatch: CLIDispatch) throws(CLIAdapterError) {
        guard dispatch.route.cli == cli else {
            throw .routeForOtherCLI(expected: cli, got: dispatch.route.cli)
        }
        guard supportedEfforts.contains(dispatch.route.effort) else {
            throw .unsupportedEffort(cli: cli, effort: dispatch.route.effort, supported: supportedEfforts)
        }
        guard RegisteredCLIAdapters.conflictingEffortSuffix(in: dispatch.route) == nil else {
            throw .conflictingModelEffort(cli: cli, model: dispatch.route.model, effort: dispatch.route.effort)
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

    /// Moves an existing raw stdout capture aside to the first free `<base>.<n>.<ext>` (`stdout.json` →
    /// `stdout.1.json`, then `stdout.2.json`, …), so the new invocation starts with an empty capture. The
    /// capture is opened `O_APPEND` and a Round reuses its Attempt's run directory, so a previous Round's
    /// output must never be read as this run's. The old capture is kept, not deleted, as evidence. A
    /// missing file is a no-op; failures are ignored, like the stale result-file removal.
    func setAsideCapture(_ capture: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: capture.path(percentEncoded: false)) else { return }
        let directory = capture.deletingLastPathComponent()
        let base = capture.deletingPathExtension().lastPathComponent
        let ext = capture.pathExtension
        var index = 1
        var destination: URL
        repeat {
            let name = ext.isEmpty ? "\(base).\(index)" : "\(base).\(index).\(ext)"
            destination = directory.appendingPathComponent(name)
            index += 1
        } while fileManager.fileExists(atPath: destination.path(percentEncoded: false))
        try? fileManager.moveItem(at: capture, to: destination)
    }
}
