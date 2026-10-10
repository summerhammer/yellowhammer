import Config
import Domain
import Foundation

/// The one generation path for a Project's scheduled jobs: building the three ``ScheduledJob``s from a
/// firing grid, composing the `PATH` they run with, and installing them as LaunchAgents. `yh setup
/// --install-jobs` and `yh doctor --fix` both call it, so a regenerated job is byte-for-byte the job setup
/// would have installed. Every side effect is an injected seam, mirroring ``Setup`` and ``Doctor``.
struct ScheduledJobInstaller {
    /// Where LaunchAgents are written (`<homeDirectory>/Library/LaunchAgents`) and every job's log path
    /// is expanded against.
    let homeDirectory: URL
    /// The resolved absolute path to the `yh` executable a generated job invokes.
    let yhExecutablePath: String
    /// The `PATH` the invoking process ran with — the starting point ``ScheduledJob/composePATH``
    /// composes from. `nil` when unset in the environment.
    let setupTimePATH: String?
    /// Whether a candidate tool path names an existing executable file.
    let fileExists: (String) -> Bool
    let launchAgents: any LaunchAgentControl
    let output: (String) -> Void

    var launchAgentsDirectory: URL {
        homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    }

    /// The author, build and land jobs `firings` implies for `projectID`.
    func jobs(projectID: ProjectID, firings: Schedule.ScheduledFirings, pathValue: String) -> [ScheduledJob] {
        let firingsByAct: [(Act, [TimeOfDay])] = [
            (.author, firings.author), (.build, firings.build), (.land, firings.land)
        ]
        return firingsByAct.map { act, firings in
            ScheduledJob(
                projectID: projectID, act: act, yhExecutablePath: yhExecutablePath, firings: firings,
                pathValue: pathValue
            )
        }
    }

    // MARK: - PATH composition

    func composedPATH(machine: MachineConfiguration) -> String {
        var resolvedToolPaths: [String] = []
        for name in ["git", "orca"] {
            if let path = ProbeExecutable.resolve(
                name: name, declared: nil, path: setupTimePATH, fileExists: fileExists
            ) {
                resolvedToolPaths.append(path)
            }
        }
        for adapter in machine.cliAdapters {
            if let path = ProbeExecutable.resolve(
                name: adapter.name, declared: adapter.executable, path: setupTimePATH, fileExists: fileExists
            ) {
                resolvedToolPaths.append(path)
            }
        }
        // A gh CLI connection needs gh at Act time: searched like at the time of use (PATH, then the Homebrew
        // directories), so its directory leads the composed PATH even when the invoking PATH lacks it.
        if let connection = gitHubCLIConnection(in: machine),
           let path = GitHubCLIExecutable.resolve(
               declared: connection.executable, path: setupTimePATH, fileExists: fileExists
           ) {
            resolvedToolPaths.append(path)
        }
        return ScheduledJob.composePATH(setupTimePATH: setupTimePATH ?? "", resolvedToolPaths: resolvedToolPaths)
    }

    /// The registry's `gh` CLI connection (a Mac holds at most one), carrying its declared executable.
    private func gitHubCLIConnection(in machine: MachineConfiguration) -> (name: String, executable: String?)? {
        for connection in machine.codeHostingConnections {
            if case .githubCLI(let executable) = connection.kind { return (connection.name, executable) }
        }
        return nil
    }

    func reportUnresolvableTools(pathValue: String, machine: MachineConfiguration) {
        let gitHubCLI = gitHubCLIConnection(in: machine).map {
            ScheduledJob.GitHubCLIRequirement(declared: $0.executable)
        }
        let missing = ScheduledJob.unresolvableTools(
            composedPATH: pathValue, declaredCLIAdapters: machine.cliAdapters, gitHubCLI: gitHubCLI,
            fileExists: fileExists
        )
        for tool in missing {
            output(
                "Warning: `\(tool)` is not on the PATH the scheduled " // glossary:ignore GL001
                    + "jobs run with (\(pathValue)); a Scheduled Invocation will not find it."
            )
        }
    }

    // MARK: - Install

    /// Installs `jobs`, returning whether any failed. With `leavingUnloadedJobsUnloaded`, a job that is
    /// not loaded has its plist rewritten but is neither enabled nor bootstrapped: unloading is how an
    /// Operator pauses a Project, and regenerating a job must not resume it.
    func install(_ jobs: [ScheduledJob], leavingUnloadedJobsUnloaded: Bool = false) async -> Bool {
        let directory = launchAgentsDirectory
        // `launchd` never creates a missing parent of `StandardOutPath`, so the jobs' log directory
        // must exist before the first firing.
        let logDirectory = homeDirectory.appending(components: "Library", "Logs", "Yellowhammer")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            output("could not create \(directory.path(percentEncoded: false)): \(error)")
            return true
        }

        var anyFailed = false
        for job in jobs {
            do {
                try await installJob(job, in: directory, leavingUnloadedJobsUnloaded: leavingUnloadedJobsUnloaded)
            } catch {
                output("Project \(job.projectID): could not load \(job.label): \(error)") // glossary:ignore GL001
                anyFailed = true
            }
        }
        return anyFailed
    }

    private func installJob(
        _ job: ScheduledJob, in directory: URL, leavingUnloadedJobsUnloaded: Bool
    ) async throws {
        let plistURL = directory.appending(component: job.fileName, directoryHint: .notDirectory)
        let data = try job.plistData(homeDirectory: homeDirectory.path(percentEncoded: false))
        let previous = try FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
            ? Data(contentsOf: plistURL) : nil
        let initialState = try await launchAgents.jobState(label: job.label)
        if initialState == .unloaded, leavingUnloadedJobsUnloaded {
            try data.write(to: plistURL, options: .atomic)
            output("Project \(job.projectID): regenerated \(job.label), left unloaded") // glossary:ignore GL001
            return
        }
        // Enabling an unchanged loaded job preserves explicit --install-jobs semantics without a reload.
        if previous == data, initialState != .unloaded {
            try await launchAgents.enable(label: job.label)
            output("Project \(job.projectID): already installed \(job.label)") // glossary:ignore GL001
            return
        }
        if initialState == .running {
            reportRunningJob(job)
            return
        }
        try await launchAgents.enable(label: job.label)
        // Revalidate immediately before bootout, after the enabling operation.
        let state = try await launchAgents.jobState(label: job.label)
        if state == .running {
            reportRunningJob(job)
            return
        }
        let replacingLoadedJob = state == .idle
        if replacingLoadedJob {
            guard previous != nil else {
                throw LaunchctlError(description: "loaded job has no existing plist to restore; leaving it loaded")
            }
            try await launchAgents.bootout(label: job.label)
        }
        do {
            try data.write(to: plistURL, options: .atomic)
            try await launchAgents.bootstrap(plistURL: plistURL)
        } catch {
            if replacingLoadedJob, let previous {
                do {
                    try previous.write(to: plistURL, options: .atomic)
                    try await launchAgents.bootstrap(plistURL: plistURL)
                    output("Project \(job.projectID): restored previous \(job.label)") // glossary:ignore GL001
                } catch let recoveryError {
                    throw LaunchctlError(
                        description: "\(error); could not restore previous \(job.label): \(recoveryError)"
                    )
                }
            }
            throw error
        }
        output("Project \(job.projectID): installed \(job.label)") // glossary:ignore GL001
    }

    private func reportRunningJob(_ job: ScheduledJob) {
        output(
            "Project \(job.projectID): skipped running \(job.label); " // glossary:ignore GL001
                + "rerun yh setup --install-jobs when the job is idle."
        )
    }
}
