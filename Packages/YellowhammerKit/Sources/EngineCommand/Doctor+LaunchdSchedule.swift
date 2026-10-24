import Config
import Domain
import Foundation
import Journal

/// One Act's LaunchAgent as `yh doctor` finds it on disk.
struct LaunchdJobState {
    let projectID: ProjectID
    let act: Act
    let installed: Bool
    let loaded: Bool
    /// How the installed `StartCalendarInterval` differs from the firings the `[schedule]` implies; nil
    /// when it matches, when the job is not installed, or when no schedule was derived to compare with.
    let difference: String?
    let executablePath: String?
    let executable: ScheduledExecutable.State

    var label: String { act.launchdLabel(projectID: projectID) }
}

extension Doctor {
    /// Reads each installed executable and schedule. With --fix, repairs affected jobs together, then
    /// re-reads the plists so a skipped or failed repair retains the actual failure or warning.
    /// Only the Project --project names is regenerated or compared against its schedule.
    func launchdFindings(
        project: ProjectConfiguration, machine: MachineConfiguration
    ) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        var expected: Schedule.ScheduledFirings?
        // A Project that records no `stagger_minutes` has no expected schedule: --fix must not regenerate
        // its jobs at offset 0, so it is reported (below) and left to `yh setup --install-jobs`.
        let recorded = project.schedule.staggerMinutes != nil
        if recorded, projectFilter == nil || projectFilter == project.id {
            do {
                expected = try project.schedule.firings()
            } catch {
                let id = project.id
                findings.append(finding(
                    .launchd, subject: id.rawValue, .warning,
                    "Project \(id.rawValue) [schedule] cannot be scheduled: \(error)", project: id
                ))
            }
        }

        let original = await launchdJobStates(projectID: project.id, expected: expected)
        if !recorded, original.contains(where: \.installed), projectFilter == nil || projectFilter == project.id {
            findings.append(finding(
                .launchd, subject: project.id.rawValue, .warning,
                "Project \(project.id.rawValue) has installed jobs but its [schedule] records no "
                    + "stagger_minutes; run yh setup --install-jobs to record the Stagger Offset and "
                    + "regenerate them",
                project: project.id
            ))
        }
        var states = original
        if fix, let expected, projectFilter == nil || projectFilter == project.id {
            let affected = original.filter { $0.installed && ($0.difference != nil || shouldRepoint($0)) }
            if !affected.isEmpty {
                findings += await regenerateJobs(
                    projectID: project.id, expected: expected, states: affected, machine: machine
                )
                states = await launchdJobStates(projectID: project.id, expected: expected)
            }
        }
        for state in states {
            let previous = original.first { $0.act == state.act }
            let regenerated = previous?.difference != nil && state.difference == nil
            findings += launchdFindings(for: state, regenerated: regenerated)
            let repointed = previous.map { shouldRepoint($0) && $0.executablePath != state.executablePath } == true
                && state.executable == .running
            if repointed {
                findings.append(finding(
                    .launchd, subject: state.label, .pass,
                    "\(state.label): repointed its installed yh \(previous?.executablePath ?? "(none readable)") "
                        + "at running yh \(ScheduledExecutable.description(runningExecutablePath))",
                    project: project.id
                ))
            }
        }
        return findings
    }

    private func shouldRepoint(_ state: LaunchdJobState) -> Bool {
        state.executable == .missing || (repoint && state.executable == .mismatched)
    }

    private func launchdJobStates(
        projectID: ProjectID, expected: Schedule.ScheduledFirings?
    ) async -> [LaunchdJobState] {
        var states: [LaunchdJobState] = []
        for act in Act.allCases {
            let label = act.launchdLabel(projectID: projectID)
            let plistURL = launchAgentsDirectory.appending(component: "\(label).plist", directoryHint: .notDirectory)
            let installed = FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
            let loaded = installed ? await launchAgents.isLoaded(label: label) : false
            let difference = installed ? expected.flatMap {
                scheduleDifference(act: act, wanted: ScheduledJobRefresh.firings(of: act, in: $0), plistURL: plistURL)
            } : nil
            let executablePath = ScheduledExecutable.installedPath(at: plistURL)
            states.append(LaunchdJobState(
                projectID: projectID, act: act, installed: installed, loaded: loaded, difference: difference,
                executablePath: executablePath,
                executable: ScheduledExecutable.inspect(
                    executablePath, running: runningExecutablePath, fileExists: fileExists
                )
            ))
        }
        return states
    }

    /// Schedule and executable repairs share setup's installer. Only affected installed jobs are
    /// regenerated, with paused jobs left unloaded and running jobs skipped by the installer.
    private func regenerateJobs(
        projectID: ProjectID, expected: Schedule.ScheduledFirings, states: [LaunchdJobState],
        machine: MachineConfiguration
    ) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        let installer = ScheduledJobInstaller(
            homeDirectory: homeDirectory, yhExecutablePath: ScheduledExecutable.resolved(runningExecutablePath),
            setupTimePATH: setupTimePATH, fileExists: fileExists, launchAgents: launchAgents, output: output
        )
        let pathValue = installer.composedPATH(machine: machine)
        installer.reportUnresolvableTools(pathValue: pathValue, machine: machine)
        var jobs: [ScheduledJob] = []
        for state in states {
            let path = shouldRepoint(state) ? runningExecutablePath : (state.executablePath ?? runningExecutablePath)
            let resolved = ScheduledExecutable.resolved(path)
            do {
                try ScheduledExecutable.validateLocation(
                    ScheduledExecutable.resolved(runningExecutablePath), homeDirectory: homeDirectory, output: output
                )
                if resolved != ScheduledExecutable.resolved(runningExecutablePath) {
                    try ScheduledExecutable.validateLocation(resolved, homeDirectory: homeDirectory, output: output)
                }
                let journalURL = JournalStore.defaultFileURL(
                    configurationDirectory: configurationDirectory, id: projectID
                )
                if let applied = try JournalStore.schemaIdentifier(at: journalURL) {
                    let candidate = ScheduledExecutable.resolved(runningExecutablePath) == resolved
                        ? JournalStore.migrationIdentifiers.last : await executableSchema(resolved)
                    try ScheduledExecutable.validateSchema(candidate, journal: applied)
                }
                jobs.append(ScheduledJob(
                    projectID: projectID, act: state.act, yhExecutablePath: resolved,
                    firings: ScheduledJobRefresh.firings(of: state.act, in: expected), pathValue: pathValue
                ))
            } catch {
                findings.append(finding(
                    .launchd, subject: state.label, .failure,
                    "\(state.label): refused regeneration at \(ScheduledExecutable.description(resolved)): \(error)",
                    project: projectID
                ))
            }
        }
        _ = await installer.install(jobs, leavingUnloadedJobsUnloaded: true)
        return findings
    }

    /// Nil when the plist at `plistURL` carries exactly the `wanted` firings; otherwise what differs.
    private func scheduleDifference(act: Act, wanted: [TimeOfDay], plistURL: URL) -> String? {
        ScheduledJobRefresh.scheduleDifference(act: act, wanted: wanted, plistURL: plistURL)
    }

    static func strayKeys(in data: Data) -> [String] { ScheduledJobRefresh.strayKeys(in: data) }

    static func installedFirings(in data: Data) -> Set<TimeOfDay>? { ScheduledJobRefresh.installedFirings(in: data) }
}
