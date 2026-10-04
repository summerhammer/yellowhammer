import Config
import Domain
import Foundation

/// One `launchd` firing grid for one Project's one Act, ready to render as a `launchd` `plist` or a
/// cron line. Pure data: nothing here touches the filesystem or reads the real environment, so setup
/// wiring (P13.2 slice B) supplies every input.
struct ScheduledJob: Equatable {
    let projectID: ProjectID
    let act: Act
    /// The resolved absolute path to the `yh` executable this job invokes.
    let yhExecutablePath: String
    /// This job's firings, in firing order, deduplicated (``Schedule/firings(staggerIndex:)``).
    let firings: [TimeOfDay]
    /// The `PATH` this job's `EnvironmentVariables` carries (see ``ScheduledJob/composePATH``).
    let pathValue: String

    /// `dev.yellowhammer.<project>.<act>`.
    var label: String {
        act.launchdLabel(projectID: projectID)
    }

    /// `<label>.plist`.
    var fileName: String {
        "\(label).plist"
    }

    /// `~/Library/Logs/Yellowhammer/<project>.<act>.log`, expanded against `homeDirectory`. Never reads
    /// the real home: the caller injects it.
    func logPath(homeDirectory: String) -> String {
        "\(homeDirectory)/Library/Logs/Yellowhammer/\(projectID.rawValue).\(act.rawValue).log"
    }
}

extension ScheduledJob {
    /// This job's `launchd` LaunchAgent, as XML property list data.
    ///
    /// Carries `Label`, `ProgramArguments`, `StartCalendarInterval` (one `{Hour, Minute}` dictionary per
    /// firing) and `EnvironmentVariables` (`PATH` only), plus `StandardOutPath`/`StandardErrorPath`.
    /// `AssociatedBundleIdentifiers` names the app, so Login Items lists the job under Yellowhammer
    /// rather than under the signing team's name.
    /// Deliberately omits `RunAtLoad`, `KeepAlive` and `ProcessType`: this is a scheduled one-shot, and
    /// `ProcessType Background` would throttle the agent CLI it dispatches.
    func plistData(homeDirectory: String) throws -> Data {
        let log = logPath(homeDirectory: homeDirectory)
        let plist: [String: Any] = [
            "Label": label,
            "AssociatedBundleIdentifiers": ["dev.yellowhammer"],
            "ProgramArguments": [yhExecutablePath, act.rawValue, "--project", projectID.rawValue],
            "StartCalendarInterval": firings.map { ["Hour": $0.hour, "Minute": $0.minute] },
            "EnvironmentVariables": ["PATH": pathValue],
            "StandardOutPath": log,
            "StandardErrorPath": log
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
    }
}

extension ScheduledJob {
    /// One `PATH=` line followed by cron lines for `jobs`, grouped so that hours sharing an identical
    /// minute list share one line. Each Project's jobs are preceded by a `# <label-prefix>` comment.
    ///
    /// A job with no firings contributes nothing (a legitimately empty grid, such as an offset-only
    /// author-less act, is silently skipped rather than emitting a malformed line).
    static func cronLines(for jobs: [ScheduledJob], pathValue: String, homeDirectory: String) -> [String] {
        var lines = ["PATH=\(pathValue)"]
        for job in jobs where !job.firings.isEmpty {
            lines.append("# \(job.label)")
            lines.append(contentsOf: job.cronLines(homeDirectory: homeDirectory))
        }
        return lines
    }

    /// This job's own cron lines: its firings grouped by minute-list, one line per group.
    private func cronLines(homeDirectory: String) -> [String] {
        var minutesByHour: [Int: [Int]] = [:]
        for firing in firings {
            minutesByHour[firing.hour, default: []].append(firing.minute)
        }
        for hour in minutesByHour.keys {
            minutesByHour[hour] = minutesByHour[hour]!.sorted()
        }

        // Group hours that share an identical (sorted) minute list.
        var groups: [(minutes: [Int], hours: [Int])] = []
        for hour in minutesByHour.keys.sorted() {
            let minutes = minutesByHour[hour]!
            if let index = groups.firstIndex(where: { $0.minutes == minutes }) {
                groups[index].hours.append(hour)
            } else {
                groups.append((minutes: minutes, hours: [hour]))
            }
        }

        let log = logPath(homeDirectory: homeDirectory)
        let command = "\(Self.shellQuoted(yhExecutablePath)) \(act.rawValue) --project \(projectID.rawValue)"
        return groups.map { group in
            let minuteField = group.minutes.map(String.init).joined(separator: ",")
            let hourField = group.hours.sorted().map(String.init).joined(separator: ",")
            return "\(minuteField) \(hourField) * * * \(command) >> \(Self.shellQuoted(log)) 2>&1"
        }
    }

    /// Single-quotes `path` when it contains anything outside `[A-Za-z0-9/._-]`; otherwise returns it
    /// unquoted. A literal `'` inside `path` is closed and re-opened (`'\''`).
    static func shellQuoted(_ path: String) -> String {
        let safe = path.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "/", ".", "_", "-": true
            default: false
            }
        }
        guard !safe else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension ScheduledJob {
    /// The `PATH` value a Scheduled Invocation's `EnvironmentVariables` carries: each resolved tool's
    /// own directory first, then every entry of the setup-time `PATH` (the environment `yh setup` ran
    /// in), then the bare POSIX default — de-duplicated, preserving first occurrence, empty entries
    /// skipped. `launchd` starts jobs with none of a login shell's `PATH`, so this composed value is
    /// what makes a Scheduled Invocation's `git`/agent-CLI lookups behave the same as an interactive one.
    static func composePATH(setupTimePATH: String, resolvedToolPaths: [String]) -> String {
        var seen = Set<String>()
        var entries: [String] = []
        func add(_ entry: Substring) {
            guard !entry.isEmpty, seen.insert(String(entry)).inserted else { return }
            entries.append(String(entry))
        }
        for toolPath in resolvedToolPaths {
            let directory = (toolPath as NSString).deletingLastPathComponent
            add(Substring(directory))
        }
        for entry in setupTimePATH.split(separator: ":", omittingEmptySubsequences: false) {
            add(entry)
        }
        for entry in "/usr/bin:/bin:/usr/sbin:/sbin".split(separator: ":") {
            add(entry)
        }
        return entries.joined(separator: ":")
    }

    /// The tools among `git`, `orca` and `declaredCLIAdapters` that a bare `launchd` environment carrying
    /// only `composedPATH` could not resolve: `fileExists` stands in for the filesystem, same seam as
    /// ``ProbeExecutable``. A declared adapter with an absolute `executable` always resolves (it never
    /// depends on `PATH`); one without falls back to a `PATH` search for its `name`, exactly as
    /// ``ProbeExecutable/resolve`` does at Act time.
    static func unresolvableTools(
        composedPATH: String, declaredCLIAdapters: [CLIAdapterDeclaration], fileExists: (String) -> Bool
    ) -> [String] {
        // git and orca are baseline tools every Act needs; a declared CLI adapter of the same name
        // overrides the baseline entry (its `executable`, when set, wins), so a Project cannot end up
        // checked twice under two different declarations for the same tool.
        var declaredExecutables: [String: String?] = ["git": nil, "orca": nil]
        var order = ["git", "orca"]
        for adapter in declaredCLIAdapters {
            if declaredExecutables[adapter.name] == nil {
                order.append(adapter.name)
            }
            declaredExecutables[adapter.name] = adapter.executable
        }

        return order.compactMap { name in
            let resolved = ProbeExecutable.resolve(
                name: name, declared: declaredExecutables[name].flatMap { $0 }, path: composedPATH,
                fileExists: fileExists
            )
            return resolved == nil ? name : nil
        }
    }
}
