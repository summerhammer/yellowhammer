import CLIAdapters
import Config
import Domain
import Foundation

/// The real Dispatch seam (roadmap P8.4): resolves the CLI Adapter a Route names, resolves its executable
/// the way the Probe does, renders the Instruction and runs the pass through ``CLIRunner``. It translates
/// and never decides: a Route with no adapter, no executable, or an effort its adapter refuses is a
/// refusal — a failure of that Route for the Attempt — and never an engine fault.
struct CLIAdapterDispatch: AgentDispatch {
    /// How long one pass may run before the adapter sends SIGTERM to its process group, when the caller
    /// sets none. A Project's `[limits] pass_timeout_minutes` sets it for every pass the Project dispatches
    /// (issue #507); this is the default that key falls back to, 60 minutes.
    static let defaultTimeout: Duration = .seconds(ProjectConfiguration.defaultPassTimeoutMinutes * 60)

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
    /// Absolute directories no pass may read — Yellowhammer's configuration directory and the login
    /// Keychains directory (issue #546). Carried into every ``CLIDispatch``.
    let protectedDirectories: [String]
    let recorder: (any DispatchPromptRecording)?
    let now: @Sendable () -> Date
    /// The Project's saved instructions, read afresh on every dispatch of a production pass. Nil means
    /// there are none. Never given to a diagnostic probe.
    let projectInstructions: ProjectInstructionsStore?

    init(
        runsDirectory: URL,
        timeout: Duration = CLIAdapterDispatch.defaultTimeout,
        declaredExecutables: [String: String] = [:],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        runner: CLIRunner? = nil,
        protectedDirectories: [String] = [],
        recorder: (any DispatchPromptRecording)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        projectInstructions: ProjectInstructionsStore? = nil
    ) {
        self.projectInstructions = projectInstructions
        self.runsDirectory = runsDirectory
        self.timeout = timeout
        self.declaredExecutables = declaredExecutables
        self.path = path
        self.environment = environment
        self.fileExists = fileExists
        self.recorder = recorder
        self.now = now
        self.runner = runner ?? CLIRunner(recorder: recorder, now: now)
        self.protectedDirectories = protectedDirectories
    }

    /// The directories a pass must not read: the configuration directory (config, run artifacts, the
    /// Journals and their backups) and `<home>/Library/Keychains`. Absolute, because an app-spawned `yh`
    /// can run with an empty environment, so `~` and `$HOME` are not reliable. The home directory comes
    /// from `FileManager`, not `$HOME`.
    static func protectedDirectories(configurationDirectory: URL) -> [String] {
        let keychains = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Keychains", directoryHint: .isDirectory)
        return [
            configurationDirectory.path(percentEncoded: false).trimmingTrailingSlash(),
            keychains.path(percentEncoded: false).trimmingTrailingSlash()
        ]
    }

    /// `<configuration directory>/runs/<project id>`.
    static func runsDirectory(configurationDirectory: URL, projectID: ProjectID) -> URL {
        configurationDirectory.appending(components: "runs", projectID.rawValue, directoryHint: .isDirectory)
    }

    /// The Project instructions one dispatch uses, resolved once and never cached, so a save made during a
    /// pass reaches the next dispatch, a resumed worker Round included.
    struct ResolvedInstructions: Equatable {
        /// The text composed into the instruction; nil when none is.
        let text: String?
        let use: ProjectInstructionsUse
        /// Set when saved instructions exist but cannot be read completely.
        let unavailableCause: String?

        static let none = ResolvedInstructions(text: nil, use: .absent, unavailableCause: nil)
    }

    func resolveProjectInstructions(for request: AgentDispatchRequest) -> ResolvedInstructions {
        guard let projectInstructions, PromptFamily(pass: request.pass)?.acceptsProjectInstructions == true else {
            return .none
        }
        switch projectInstructions.read() {
        case .absent:
            return .none
        case .saved(let revision):
            return ResolvedInstructions(text: revision.text, use: .revision(revision.id), unavailableCause: nil)
        case .unavailable(let cause):
            return ResolvedInstructions(text: nil, use: .unavailable(cause: cause), unavailableCause: cause)
        }
    }

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        let resolved = resolveProjectInstructions(for: request)
        if let cause = resolved.unavailableCause {
            let reason = "the Project's saved instructions could not be used: \(cause). Reset or re-save them "
                + "in Settings → Configuration → Prompts"
            recordRefusalIfNeeded(request: request, resolved: resolved, reason: reason, outputSchema: nil)
            throw AgentDispatchRefusal(reason: reason)
        }
        let cli = request.route.cli
        guard let adapter = CLIAdapterRegistry.adapter(named: cli) else {
            let reason = "no CLI Adapter for `\(cli)`"
            recordRefusalIfNeeded(request: request, resolved: resolved, reason: reason, outputSchema: nil)
            throw AgentDispatchRefusal(reason: reason)
        }
        guard let executable = ProbeExecutable.resolve(
            name: cli, declared: declaredExecutables[cli], path: path, fileExists: fileExists
        ) else {
            let reason = "no executable found for `\(cli)`: declare `executable` under `[cli.\(cli)]` in "
                + "config.toml, or add `\(cli)` to PATH"
            recordRefusalIfNeeded(
                request: request, resolved: resolved, reason: reason,
                outputSchema: adapter.outputSchema(for: request.pass)
            )
            throw AgentDispatchRefusal(reason: reason)
        }
        let dispatch = makeDispatch(for: request, executable: executable, resolved: resolved)
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

    private func recordRefusalIfNeeded(
        request: AgentDispatchRequest, resolved: ResolvedInstructions, reason: String, outputSchema: String?
    ) {
        guard let provenance = request.provenance, let recorder else { return }
        let record = DispatchPromptRecord(
            provenance: provenance,
            route: request.route.description,
            pass: request.pass,
            dispatchedAt: now(),
            defaultVersion: provenance.family.defaultVersion,
            projectInstructions: resolved.use,
            session: request.resumeSession != nil ? .resumed : .new,
            instruction: request.instruction.render(projectInstructions: resolved.text),
            outputSchema: outputSchema,
            launch: .notLaunched(cause: reason)
        )
        _ = recorder.capture(record)
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

    /// The request as a ``CLIDispatch``. The rendered instruction names no result file: the adapter
    /// persists the structured response as `result.json` in the run directory, for validation, without
    /// the model being told where.
    func makeDispatch(
        for request: AgentDispatchRequest, executable: String, resolved: ResolvedInstructions = .none
    ) -> CLIDispatch {
        let directory = runDirectory(for: request)
        return CLIDispatch(
            route: request.route,
            pass: request.pass,
            instruction: request.instruction.render(projectInstructions: resolved.text),
            worktreePath: request.worktreePath,
            runDirectory: directory,
            timeout: timeout,
            resume: request.resumeSession.map { CLISession(rawValue: $0) },
            additionalReadableDirectories: request.additionalReadableDirectories,
            additionalWritableDirectories: request.additionalWritableDirectories,
            protectedDirectories: protectedDirectories,
            executable: executable,
            environment: environment,
            provenance: request.provenance,
            projectInstructions: resolved.use
        )
    }
}

private extension String {
    /// The path without a trailing `/`, so `Read(//<dir>/**)` rules do not carry a double slash.
    func trimmingTrailingSlash() -> String {
        var trimmed = self
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
