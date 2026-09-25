import CLIAdapters
import Domain
import Foundation

/// The real Dispatch seam (roadmap P8.4): resolves the CLI Adapter a Route names, resolves its executable
/// the way the Probe does, renders the Instruction and runs the pass through ``CLIRunner``. It translates
/// and never decides: a Route with no adapter, no executable, or an effort its adapter refuses is a
/// refusal — a failure of that Route for the Attempt — and never an engine fault.
struct CLIAdapterDispatch: AgentDispatch {
    /// How long one pass may run before the adapter sends SIGTERM to its process group. A repo-local
    /// default: the spec gives no timeout value, so this is open in the spec.
    static let defaultTimeout: Duration = .seconds(30 * 60)

    /// Where run directories live: `runs/<runID>/<issueID>/<attemptID>-<pass>` under the Project's
    /// directory in the configuration directory — Yellowhammer-owned and outside every Worktree, so an
    /// agent CLI cannot edit its own result file's siblings by editing the repository.
    let runsDirectory: URL
    let timeout: Duration
    /// Each declared CLI Adapter's executable from the machine configuration, by CLI name.
    let declaredExecutables: [String: String]
    let path: String?
    let environment: [String: String]
    let fileExists: @Sendable (String) -> Bool
    let runner: CLIRunner

    init(
        runsDirectory: URL,
        timeout: Duration = CLIAdapterDispatch.defaultTimeout,
        declaredExecutables: [String: String] = [:],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        runner: CLIRunner = CLIRunner()
    ) {
        self.runsDirectory = runsDirectory
        self.timeout = timeout
        self.declaredExecutables = declaredExecutables
        self.path = path
        self.environment = environment
        self.fileExists = fileExists
        self.runner = runner
    }

    /// `<configuration directory>/runs/<project id>`.
    static func runsDirectory(configurationDirectory: URL, projectID: ProjectID) -> URL {
        configurationDirectory.appending(components: "runs", projectID.rawValue, directoryHint: .isDirectory)
    }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        let cli = request.route.cli
        guard let adapter = CLIAdapterRegistry.adapter(named: cli) else {
            throw AgentDispatchRefusal(reason: "no CLI Adapter for `\(cli)`")
        }
        guard let executable = ProbeExecutable.resolve(
            name: cli, declared: declaredExecutables[cli], path: path, fileExists: fileExists
        ) else {
            throw AgentDispatchRefusal(
                reason: "no executable found for `\(cli)`: declare `executable` under `[cli.\(cli)]` in "
                    + "config.toml, or add `\(cli)` to PATH"
            )
        }
        let dispatch = makeDispatch(for: request, executable: executable)
        do {
            let report = try await runner.run(dispatch, adapter: adapter)
            return AgentDispatchReport(
                outcome: report.outcome, session: report.session?.rawValue, origin: .agentCLIProcess,
                leftovers: report.leftovers, snapshot: report.snapshot
            )
        } catch let error as CLIAdapterError {
            throw AgentDispatchRefusal(reason: error.description)
        }
    }

    /// The run directory for one pass of one Attempt, under `runsDirectory`:
    /// `<runID>/<issueID>/<attemptID>-<pass>`. The one place this layout is spelled out; the lease-
    /// reclaim sweep's ``RunResultReading`` seam (P8.10) reuses this rather than restating it.
    static func runDirectory(
        runsDirectory: URL, runID: RunID, issueID: String, attemptID: Int64, pass: RunPass
    ) -> URL {
        runsDirectory
            .appending(component: runID.rawValue, directoryHint: .isDirectory)
            .appending(component: issueID, directoryHint: .isDirectory)
            .appending(component: "\(attemptID)-\(pass.rawValue)", directoryHint: .isDirectory)
    }

    /// The run directory for one pass of one Attempt.
    func runDirectory(for request: AgentDispatchRequest) -> URL {
        Self.runDirectory(
            runsDirectory: runsDirectory, runID: request.runID, issueID: request.issueID,
            attemptID: request.attemptID, pass: request.pass
        )
    }

    /// The request as a ``CLIDispatch``. The Instruction's result file is the `result.json` the adapter
    /// places in the run directory, so what the agent is told to write is what the dual-key check reads.
    func makeDispatch(for request: AgentDispatchRequest, executable: String) -> CLIDispatch {
        let directory = runDirectory(for: request)
        let resultFile = directory.appending(component: "result.json", directoryHint: .notDirectory)
        let instruction = request.instruction.withResultFilePath(resultFile.path(percentEncoded: false))
        return CLIDispatch(
            route: request.route,
            pass: request.pass,
            instruction: instruction.render(),
            worktreePath: request.worktreePath,
            runDirectory: directory,
            timeout: timeout,
            resume: request.resumeSession.map { CLISession(rawValue: $0) },
            additionalReadableDirectories: request.additionalReadableDirectories,
            additionalWritableDirectories: request.additionalWritableDirectories,
            executable: executable,
            environment: environment
        )
    }
}
