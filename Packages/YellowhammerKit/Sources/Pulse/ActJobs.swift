import Domain

/// The `launchd` jobs that are alive at one instant, as the labels `launchctl list` printed.
///
/// Fallback status evidence for a Project when its Journal has no current lease or cannot be read.
/// Pure data and parsing; running `launchctl` is the caller's.
public struct ActJobs: Equatable, Sendable {
    /// Labels of jobs with a running process.
    private let aliveLabels: Set<String>
    /// Labels of every job `launchctl list` printed, alive or not. Nil when `launchctl` was not read.
    private let loadedLabels: Set<String>?

    /// No job is alive, and nothing was read about which are loaded.
    public static let none = ActJobs(aliveLabels: [])

    public init(aliveLabels: Set<String>, loadedLabels: Set<String>? = nil) {
        self.aliveLabels = aliveLabels
        self.loadedLabels = loadedLabels
    }

    /// Whether all three of this Project's Act jobs are loaded in `launchd`; nil when `launchctl` was not read.
    public func areLoaded(projectID: ProjectID) -> Bool? {
        guard let loadedLabels else { return nil }
        return Act.allCases.allSatisfy { loadedLabels.contains($0.launchdLabel(projectID: projectID)) }
    }

    /// True when any of this Project's three Act jobs is alive. Labels match exactly, so another
    /// Project's job, or an unrelated job whose label merely contains ours, never counts.
    public func isAlive(projectID: ProjectID) -> Bool {
        Act.allCases.contains { aliveLabels.contains($0.launchdLabel(projectID: projectID)) }
    }

    /// Parses `launchctl list` output: a `PID\tStatus\tLabel` header, then one `<pid or ->\t<status>\t<label>`
    /// line per job. A job is alive when its PID column is a positive integer. The header and malformed
    /// lines are ignored.
    public static func parse(launchctlList output: String) -> ActJobs {
        var alive: Set<String> = []
        var loaded: Set<String> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            if columns[0] == "-" || Int(columns[0]) != nil { loaded.insert(String(columns[2])) }
            if let pid = Int(columns[0]), pid > 0 { alive.insert(String(columns[2])) }
        }
        return ActJobs(aliveLabels: alive, loadedLabels: loaded)
    }
}
