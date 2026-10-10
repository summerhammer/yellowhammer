import Config
import Domain
import Foundation

/// One Act's LaunchAgent as `yh doctor` finds it on disk.
struct LaunchdJobState {
    let projectID: ProjectID
    let act: Act
    let installed: Bool
    let loaded: Bool
    /// How the installed `StartCalendarInterval` differs from the firings the `[schedule]` implies; nil
    /// when it matches, when the job is not installed, or when no schedule was derived to compare with.
    let difference: String?

    var label: String { act.launchdLabel(projectID: projectID) }
}

extension Doctor {
    /// The findings for one Project's three Acts. With `--fix`, a Project with a differing job has its
    /// installed jobs regenerated and the check re-run against what is then on disk, so a job that could
    /// not be regenerated (running, or `launchctl` refused) still warns.
    ///
    /// Only the Project `--project` names is ever regenerated or compared against its schedule.
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

        var states = await launchdJobStates(projectID: project.id, expected: expected)
        var regenerated: Set<Act> = []
        if fix, let expected, states.contains(where: { $0.difference != nil }) {
            await regenerateJobs(projectID: project.id, expected: expected, states: states, machine: machine)
            let differing = Set(states.filter { $0.difference != nil }.map(\.act))
            states = await launchdJobStates(projectID: project.id, expected: expected)
            regenerated = differing.intersection(states.filter { $0.difference == nil }.map(\.act))
        }
        for state in states {
            findings += launchdFindings(for: state, regenerated: regenerated.contains(state.act))
        }
        return findings
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
            states.append(LaunchdJobState(
                projectID: projectID, act: act, installed: installed, loaded: loaded, difference: difference
            ))
        }
        return states
    }

    /// Rewrites the Project's installed jobs through the generation path `yh setup --install-jobs` uses.
    /// A job that is not installed stays absent (Check 5 reports it); one that is installed but not loaded
    /// is rewritten and stays unloaded.
    private func regenerateJobs(
        projectID: ProjectID, expected: Schedule.ScheduledFirings, states: [LaunchdJobState],
        machine: MachineConfiguration
    ) async {
        let installer = ScheduledJobInstaller(
            homeDirectory: homeDirectory, yhExecutablePath: runningExecutablePath, setupTimePATH: setupTimePATH,
            fileExists: fileExists, launchAgents: launchAgents, output: output
        )
        let pathValue = installer.composedPATH(machine: machine)
        installer.reportUnresolvableTools(pathValue: pathValue, machine: machine)
        let installedActs = Set(states.filter(\.installed).map(\.act))
        let jobs = installer.jobs(projectID: projectID, firings: expected, pathValue: pathValue)
            .filter { installedActs.contains($0.act) }
        _ = await installer.install(jobs, leavingUnloadedJobsUnloaded: true)
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
        guard let data = try? Data(contentsOf: plistURL), let installed = Self.installedFirings(in: data) else {
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

    /// The set of `{Hour, Minute}` firings in a LaunchAgent plist's `StartCalendarInterval` (one
    /// dictionary or an array of them; absent means none). Nil when the plist is not a dictionary, or an
    /// entry is not a fixed in-range Hour and Minute — a wildcard entry is not a firing setup writes.
    static func installedFirings(in data: Data) -> Set<TimeOfDay>? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return nil }
        guard let raw = plist["StartCalendarInterval"] else { return [] }
        let entries: [[String: Any]]
        if let dictionary = raw as? [String: Any] {
            entries = [dictionary]
        } else if let array = raw as? [[String: Any]] {
            entries = array
        } else {
            return nil
        }
        var firings = Set<TimeOfDay>()
        for entry in entries {
            guard let hour = entry["Hour"] as? Int, let minute = entry["Minute"] as? Int,
                  let time = TimeOfDay(hour: hour, minute: minute)
            else { return nil }
            firings.insert(time)
        }
        return firings
    }
}
