import Config
import Domain
import Foundation

/// Regenerates a Project's installed LaunchAgents whose `StartCalendarInterval` differs from the firings its
/// `[schedule]` implies, through the one generation path (``ScheduledJobInstaller``). `yh doctor --fix`
/// shares its plist reading and comparison; every Act uses ``refresh(project:machine:)`` at its start and its
/// end (Schedule Stagger Ruling item 4, issue #682), because a job whose Act is running is skipped by the
/// installer and nothing else would retry it: the app may not be resident, and a hand-edited TOML is never
/// regenerated at all. Every side effect is an injected seam.
struct ScheduledJobRefresh {
    let homeDirectory: URL
    let launchAgents: any LaunchAgentControl
    let fileExists: (String) -> Bool
    let setupTimePATH: String?
    let output: (String) -> Void

    /// The seams a real Act runs with: the user's home, `launchctl`, and the Act's own stderr.
    static func live() -> ScheduledJobRefresh {
        ScheduledJobRefresh(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            launchAgents: LaunchctlLaunchAgentControl(), fileExists: ExecutableFile.isRunnable,
            setupTimePATH: ProcessInfo.processInfo.environment["PATH"],
            output: { ActLog.writeToStandardError($0) }
        )
    }

    /// ``refresh(project:machine:)`` for the Project `projectArgument` names, loaded fresh from disk. A
    /// configuration that cannot be resolved is the Act's own error to report, so here it is skipped.
    func refreshAfterResolving(_ projectArgument: String, configurationDirectory: URL) async {
        guard let (configuration, resolved) = try? ProjectResolution.resolve(
            projectArgument: projectArgument, configurationDirectory: configurationDirectory
        ) else { return }
        await refresh(project: resolved, machine: configuration.machine)
    }

    private var launchAgentsDirectory: URL {
        homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    }

    /// Regenerates `project`'s own stale installed jobs, one output line per job regenerated or failed and
    /// none when nothing differs. Skips a Project that records no `stagger_minutes` (setup's job), an
    /// unschedulable `[schedule]`, a job that is not installed, and a running job (the installer's rule). A
    /// job keeps its installed executable path and, when unloaded, stays unloaded. Writes no configuration
    /// and never throws: an error is a line of output, not a failure of the Act.
    func refresh(project: ProjectConfiguration, machine: MachineConfiguration) async {
        guard project.schedule.staggerMinutes != nil,
              let expected = try? project.schedule.firings() else { return }
        let installer = ScheduledJobInstaller(
            homeDirectory: homeDirectory, yhExecutablePath: "", setupTimePATH: setupTimePATH,
            fileExists: fileExists, launchAgents: launchAgents, output: output
        )
        var stale: [(act: Act, path: String)] = []
        for act in Act.allCases {
            let plistURL = launchAgentsDirectory.appending(
                component: "\(act.launchdLabel(projectID: project.id)).plist", directoryHint: .notDirectory
            )
            guard FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false)),
                  Self.scheduleDifference(
                      act: act, wanted: Self.firings(of: act, in: expected), plistURL: plistURL
                  ) != nil,
                  let path = ScheduledExecutable.installedPath(at: plistURL)
            else { continue }
            stale.append((act, path))
        }
        guard !stale.isEmpty else { return }
        let pathValue = installer.composedPATH(machine: machine)
        let jobs = stale.map { act, path in
            ScheduledJob(
                projectID: project.id, act: act, yhExecutablePath: path,
                firings: Self.firings(of: act, in: expected), pathValue: pathValue
            )
        }
        _ = await installer.install(jobs, leavingUnloadedJobsUnloaded: true)
    }

    static func firings(of act: Act, in firings: Schedule.ScheduledFirings) -> [TimeOfDay] {
        switch act {
        case .author: firings.author
        case .build: firings.build
        case .land: firings.land
        }
    }

    /// Nil when the plist at `plistURL` carries exactly the `wanted` firings; otherwise what differs.
    static func scheduleDifference(act: Act, wanted: [TimeOfDay], plistURL: URL) -> String? {
        guard let data = try? Data(contentsOf: plistURL) else {
            return "its StartCalendarInterval could not be read as Hour and Minute firings"
        }
        let stray = strayKeys(in: data)
        if !stray.isEmpty {
            return "its StartCalendarInterval restricts a firing by \(stray.joined(separator: ", ")), "
                + "which setup never writes"
        }
        guard let installed = installedFirings(in: data) else {
            return "its StartCalendarInterval could not be read as Hour and Minute firings"
        }
        let wantedSet = Set(wanted)
        guard installed != wantedSet else { return nil }

        var parts = ["\(installed.count) installed firings, \(wantedSet.count) implied by [schedule]"]
        let missing = sorted(wantedSet.subtracting(installed))
        if let first = missing.first {
            parts.append("missing \(first)" + (missing.count > 1 ? " and \(missing.count - 1) more" : ""))
        }
        let unexpected = sorted(installed.subtracting(wantedSet))
        if let first = unexpected.first {
            parts.append("unexpected \(first)" + (unexpected.count > 1 ? " and \(unexpected.count - 1) more" : ""))
        }
        if act == .author, !missing.isEmpty {
            parts[0] = "the author job fires after every periodic land tick (Multi-Feature Night Ruling): " + parts[0]
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
