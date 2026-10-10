import Config
import Domain
import Foundation

extension Setup {
    /// Step 6.5, between provisioning and notification registration: generates every eligible Project's
    /// three scheduled jobs (author/build/land) and, per `options.jobs` (or the interactive answer when
    /// it was not given), installs or exports them. Eligible = a valid Project whose provisioning did
    /// not fail. Returns whether this step hit an error that should fail setup.
    func handleScheduledJobs(
        configuration: Configuration, machine: MachineConfiguration, provisioningFailedIDs: Set<ProjectID>
    ) async -> Bool {
        let request = resolveJobsRequest()
        guard case .none = request else {
            return await performScheduledJobs(
                request: request, configuration: configuration, machine: machine,
                provisioningFailedIDs: provisioningFailedIDs
            )
        }
        if !isInteractive {
            output("Scheduled jobs not installed; rerun with --install-jobs or --export-jobs <directory>.")
        }
        return false
    }

    /// `options.jobs` when it names something; otherwise, interactively, asks — never in `--init` or
    /// `--config` mode, where an unset `options.jobs` stays `.none`.
    private func resolveJobsRequest() -> JobsRequest {
        guard case .none = options.jobs, isInteractive else { return options.jobs }
        guard let line = console.ask("Install the scheduled jobs (three LaunchAgents per Project) now? [Y/n] ")
        else {
            return .none
        }
        let answer = line.trimmingCharacters(in: .whitespaces).lowercased()
        return answer.isEmpty || answer == "y" || answer == "yes" ? .install : .none
    }

    private func performScheduledJobs(
        request: JobsRequest, configuration: Configuration, machine: MachineConfiguration,
        provisioningFailedIDs: Set<ProjectID>
    ) async -> Bool {
        let eligibleProjects = configuration.projects.filter { !provisioningFailedIDs.contains($0.id) }
        guard !eligibleProjects.isEmpty else { return false }

        // `configuration.projects` is sorted by id (`Configuration`'s own contract); the stagger index
        // is a Project's position in that same order, so an ineligible sibling never shifts it.
        let allIDsSorted = configuration.projects.map(\.id)
        let pathValue = composedPATH(machine: machine)
        reportUnresolvableTools(pathValue: pathValue, machine: machine)

        var jobs: [ScheduledJob] = []
        var anyFailed = false
        for project in eligibleProjects {
            guard let staggerIndex = allIDsSorted.firstIndex(of: project.id) else { continue }
            do {
                let firings = try project.schedule.firings(staggerIndex: staggerIndex)
                let firingsByAct: [(Act, [TimeOfDay])] = [
                    (.author, firings.author), (.build, firings.build), (.land, firings.land)
                ]
                jobs.append(contentsOf: firingsByAct.map { act, firings in
                    ScheduledJob(
                        projectID: project.id, act: act, yhExecutablePath: yhExecutablePath, firings: firings,
                        pathValue: pathValue
                    )
                })
                output(
                    "Project \(project.id): scheduled author \(firings.author.count), " // glossary:ignore GL001
                        + "build \(firings.build.count), land \(firings.land.count) "
                        + "(\(firings.flush.count) flush) firings"
                )
            } catch {
                output("Project \(project.id): \(error)") // glossary:ignore GL001
                anyFailed = true
            }
        }

        switch request {
        case .none:
            return anyFailed
        case .install:
            let installFailed = await installJobs(jobs)
            return anyFailed || installFailed
        case .export(let directory, let format):
            let exportFailed = exportJobs(jobs, pathValue: pathValue, to: directory, format: format)
            return anyFailed || exportFailed
        }
    }

    // MARK: - PATH composition

    private func composedPATH(machine: MachineConfiguration) -> String {
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
        // directories), so its directory leads the composed PATH even when setup's own PATH lacks it.
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

    private func reportUnresolvableTools(pathValue: String, machine: MachineConfiguration) {
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

    private var launchAgentsDirectory: URL {
        homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    }

    private func installJobs(_ jobs: [ScheduledJob]) async -> Bool {
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
                try await installJob(job, in: directory)
            } catch {
                output("Project \(job.projectID): could not load \(job.label): \(error)") // glossary:ignore GL001
                anyFailed = true
            }
        }
        return anyFailed
    }

    private func installJob(_ job: ScheduledJob, in directory: URL) async throws {
        let plistURL = directory.appending(component: job.fileName, directoryHint: .notDirectory)
        let data = try job.plistData(homeDirectory: homeDirectory.path(percentEncoded: false))
        let previous = try FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
            ? Data(contentsOf: plistURL) : nil
        let initialState = try await launchAgents.jobState(label: job.label)
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

    // MARK: - Export

    private func exportJobs(_ jobs: [ScheduledJob], pathValue: String, to directory: URL, format: JobsFormat) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            output("could not create \(directory.path(percentEncoded: false)): \(error)")
            return true
        }

        switch format {
        case .launchd:
            var anyFailed = false
            for job in jobs {
                let plistURL = directory.appending(component: job.fileName, directoryHint: .notDirectory)
                do {
                    let data = try job.plistData(homeDirectory: homeDirectory.path(percentEncoded: false))
                    try data.write(to: plistURL, options: .atomic)
                    output("wrote \(plistURL.path(percentEncoded: false))")
                } catch {
                    output("could not write \(plistURL.path(percentEncoded: false)): \(error)")
                    anyFailed = true
                }
            }
            return anyFailed
        case .cron:
            let crontabURL = directory.appending(component: "yellowhammer.crontab", directoryHint: .notDirectory)
            let lines = ScheduledJob.cronLines(
                for: jobs, pathValue: pathValue, homeDirectory: homeDirectory.path(percentEncoded: false)
            )
            let text = lines.joined(separator: "\n") + "\n"
            do {
                try text.write(to: crontabURL, atomically: true, encoding: .utf8)
                let path = crontabURL.path(percentEncoded: false)
                output("wrote \(path)")
                output(
                    "merge \(path) into your crontab (crontab -l first, then edit — " // glossary:ignore GL001
                        + "`crontab \(path)` on its own replaces the whole crontab outright)"
                )
                return false
            } catch {
                output("could not write \(crontabURL.path(percentEncoded: false)): \(error)")
                return true
            }
        }
    }
}
