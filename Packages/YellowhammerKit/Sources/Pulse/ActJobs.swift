import Domain

/// The `launchd` jobs that are alive at one instant, as the labels `launchctl list` printed.
///
/// A Project is `working` exactly when one of its three Act jobs is alive: tested on the job, never on
/// a Lease. Pure data and parsing; running `launchctl` is the caller's.
public struct ActJobs: Equatable, Sendable {
    /// Labels of jobs with a running process.
    private let aliveLabels: Set<String>

    /// No job is alive.
    public static let none = ActJobs(aliveLabels: [])

    public init(aliveLabels: Set<String>) {
        self.aliveLabels = aliveLabels
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
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, let pid = Int(columns[0]), pid > 0 else { continue }
            alive.insert(String(columns[2]))
        }
        return ActJobs(aliveLabels: alive)
    }
}
