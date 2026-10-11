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

    /// The generation path shared with `yh doctor --fix`, wired to this setup's seams.
    private var jobInstaller: ScheduledJobInstaller {
        ScheduledJobInstaller(
            homeDirectory: homeDirectory, yhExecutablePath: yhExecutablePath, setupTimePATH: setupTimePATH,
            fileExists: fileExists, launchAgents: launchAgents, output: output
        )
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
        let installer = jobInstaller
        let pathValue = installer.composedPATH(machine: machine)
        installer.reportUnresolvableTools(pathValue: pathValue, machine: machine)

        var jobs: [ScheduledJob] = []
        var anyFailed = false
        for project in eligibleProjects {
            guard let staggerIndex = allIDsSorted.firstIndex(of: project.id) else { continue }
            do {
                let firings = try project.schedule.firings(staggerIndex: staggerIndex)
                jobs.append(contentsOf: installer.jobs(projectID: project.id, firings: firings, pathValue: pathValue))
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
            let installFailed = await installer.install(jobs)
            return anyFailed || installFailed
        case .export(let directory, let format):
            let exportFailed = exportJobs(jobs, pathValue: pathValue, to: directory, format: format)
            return anyFailed || exportFailed
        }
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
