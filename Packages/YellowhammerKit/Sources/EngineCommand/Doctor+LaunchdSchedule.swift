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
        project: ProjectConfiguration, staggerIndex: Int, machine: MachineConfiguration
    ) async -> [DoctorFinding] {
        var findings: [DoctorFinding] = []
        var expected: Schedule.ScheduledFirings?
        if projectFilter == nil || projectFilter == project.id {
            do {
                expected = try project.schedule.firings(staggerIndex: staggerIndex)
            } catch {
                let id = project.id
                findings.append(finding(
                    .launchd, subject: id.rawValue, .warning,
                    "Project \(id.rawValue) [schedule] cannot be scheduled: \(error)", project: id
                ))
            }
        }

        let original = await launchdJobStates(projectID: project.id, expected: expected)
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
                scheduleDifference(wanted: Self.firings(of: act, in: $0), plistURL: plistURL)
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
                    firings: Self.firings(of: state.act, in: expected), pathValue: pathValue
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

    private static func firings(of act: Act, in firings: Schedule.ScheduledFirings) -> [TimeOfDay] {
        switch act {
        case .author: firings.author
        case .build: firings.build
        case .land: firings.land
        }
    }

    /// Nil when the plist at `plistURL` carries exactly the `wanted` firings; otherwise what differs.
    private func scheduleDifference(wanted: [TimeOfDay], plistURL: URL) -> String? {
        guard let data = try? Data(contentsOf: plistURL) else {
            return "its StartCalendarInterval could not be read as Hour and Minute firings"
        }
        let stray = Self.strayKeys(in: data)
        if !stray.isEmpty {
            return "its StartCalendarInterval restricts a firing by \(stray.joined(separator: ", ")), "
                + "which setup never writes"
        }
        guard let installed = Self.installedFirings(in: data) else {
            return "its StartCalendarInterval could not be read as Hour and Minute firings"
        }
        let wantedSet = Set(wanted)
        guard installed != wantedSet else { return nil }

        var parts = ["\(installed.count) installed firings, \(wantedSet.count) implied by [schedule]"]
        let missing = Self.sorted(wantedSet.subtracting(installed))
        if let first = missing.first {
            parts.append("missing \(first)" + (missing.count > 1 ? " and \(missing.count - 1) more" : ""))
        }
        let unexpected = Self.sorted(installed.subtracting(wantedSet))
        if let first = unexpected.first {
            parts.append("unexpected \(first)" + (unexpected.count > 1 ? " and \(unexpected.count - 1) more" : ""))
        }
        return parts.joined(separator: ", ")
    }

    private static func sorted(_ times: Set<TimeOfDay>) -> [TimeOfDay] {
        times.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    /// The `StartCalendarInterval` entries of a LaunchAgent plist (one dictionary or an array of them;
    /// absent means none). Nil when the plist is not a dictionary or the value is neither shape.
    private static func intervalEntries(in data: Data) -> [[String: Any]]? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        guard let raw = plist["StartCalendarInterval"] else { return [] }
        if let dictionary = raw as? [String: Any] { return [dictionary] }
        return raw as? [[String: Any]]
    }

    /// The keys, other than `Hour` and `Minute`, that any `StartCalendarInterval` entry carries (`Weekday`,
    /// `Day`, `Month`), sorted. Such an entry restricts the firing, which setup never writes.
    static func strayKeys(in data: Data) -> [String] {
        let keys = (intervalEntries(in: data) ?? []).flatMap(\.keys)
        return Set(keys).subtracting(["Hour", "Minute"]).sorted()
    }

    /// The set of `{Hour, Minute}` firings in a LaunchAgent plist's `StartCalendarInterval` (one
    /// dictionary or an array of them; absent means none). Nil when the plist is not a dictionary, or an
    /// entry is not exactly a fixed in-range Hour and Minute — a wildcard entry, or one constrained by
    /// `Weekday`, `Day` or `Month`, is not a firing setup writes.
    static func installedFirings(in data: Data) -> Set<TimeOfDay>? {
        guard let entries = intervalEntries(in: data) else { return nil }
        var firings = Set<TimeOfDay>()
        for entry in entries {
            guard Set(entry.keys) == ["Hour", "Minute"],
                  let hour = entry["Hour"] as? Int, let minute = entry["Minute"] as? Int,
                  let time = TimeOfDay(hour: hour, minute: minute)
            else { return nil }
            firings.insert(time)
        }
        return firings
    }
}
