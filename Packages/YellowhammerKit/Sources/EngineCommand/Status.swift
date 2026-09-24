import Config
import Domain
import Foundation
import Journal

/// `yh status`'s orchestration, with every side effect injected as a seam, mirroring ``Doctor``. Reads
/// only — never installs, unloads or migrates anything, and never opens a Journal for write (spec's
/// Surface 3, R8: on-demand inspection). One section per Project, no cross-Project verdict.
struct Status {
    let configurationDirectory: URL
    let homeDirectory: URL
    let output: (String) -> Void
    let launchAgents: any LaunchAgentInspecting
    let sleepHistory: any SleepHistorySource
    let now: Date
    let calendar: Calendar
    /// Only report this Project, when set.
    let projectFilter: ProjectID?
    /// How many past Nights (`--nights`) to examine for a missed Night.
    let examinedNights: Int

    var machineFileURL: URL {
        configurationDirectory.appending(component: "config.toml", directoryHint: .notDirectory)
    }

    var launchAgentsDirectory: URL {
        homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    }

    /// Runs the whole report: loads configuration, prints one section per (matching) Project — invalid
    /// Projects first, then valid ones — and returns what it found so tests can inspect it directly.
    @discardableResult
    func run() async -> StatusReport {
        guard let configuration = loadConfiguration() else {
            return StatusReport(
                projectStatuses: [], invalidProjectStatuses: [], machineFileFailed: true, unknownProject: false
            )
        }

        let matchingProjects = configuration.projects.filter { matchesFilter(id: $0.id, file: nil) }
        let matchingInvalid = configuration.invalidProjects.filter { matchesFilter(id: $0.id, file: $0.file) }
        guard projectFilter == nil || !matchingProjects.isEmpty || !matchingInvalid.isEmpty else {
            output("no Project \(projectFilter!.rawValue) in configuration") // glossary:ignore GL001
            return StatusReport(
                projectStatuses: [], invalidProjectStatuses: [], machineFileFailed: false, unknownProject: true
            )
        }

        let invalidStatuses = matchingInvalid.map(Self.invalidProjectStatus)
        for status in invalidStatuses { printInvalidProjectSection(status) }

        let projectStatuses = await projectStatuses(matchingProjects, allProjectIDs: configuration.projects.map(\.id))
        for status in projectStatuses { printProjectSection(status) }

        return StatusReport(
            projectStatuses: projectStatuses, invalidProjectStatuses: invalidStatuses,
            machineFileFailed: false, unknownProject: false
        )
    }

    private func loadConfiguration() -> Configuration? {
        do {
            return try Configuration.load(directory: configurationDirectory)
        } catch {
            output("\(machineFileURL.path(percentEncoded: false)) is invalid: \(error)")
            return nil
        }
    }

    /// `--project` matches a valid Project by id, or an invalid one by id when known or by its file's
    /// last path component (`<id>.toml`) otherwise.
    private func matchesFilter(id: ProjectID?, file: String?) -> Bool {
        guard let projectFilter else { return true }
        if let id { return id == projectFilter }
        guard let file else { return false }
        return (file as NSString).lastPathComponent == "\(projectFilter.rawValue).toml"
    }

    private static func invalidProjectStatus(_ invalid: InvalidProject) -> InvalidProjectStatus {
        InvalidProjectStatus(file: invalid.file, id: invalid.id, errors: invalid.errors.map { "\($0)" })
    }

    private func projectStatuses(
        _ projects: [ProjectConfiguration], allProjectIDs: [ProjectID]
    ) async -> [ProjectStatus] {
        let disabledLabels = await launchAgents.disabledLabels()
        let sleepHistory = await sleepHistory.sleepHistory()

        var statuses: [ProjectStatus] = []
        for project in projects {
            guard let staggerIndex = allProjectIDs.firstIndex(of: project.id) else { continue }
            let status = await projectStatus(
                project: project, staggerIndex: staggerIndex, disabledLabels: disabledLabels, sleepHistory: sleepHistory
            )
            statuses.append(status)
        }
        return statuses
    }
}

/// Everything `Status.run()` gathered, for the command to decide its exit code and for tests to
/// inspect directly.
struct StatusReport: Sendable {
    let projectStatuses: [ProjectStatus]
    let invalidProjectStatuses: [InvalidProjectStatus]
    /// The machine file itself failed to load: nothing else runs.
    let machineFileFailed: Bool
    /// `--project` named a Project that configuration has neither as valid nor as invalid.
    let unknownProject: Bool
}

/// A Project file refused at load: its Acts exit before initializing, so no Journal or `launchd`
/// inspection is possible for it.
struct InvalidProjectStatus: Sendable {
    let file: String
    let id: ProjectID?
    let errors: [String]
}

/// One Project's `yh status` section.
struct ProjectStatus: Sendable {
    let projectID: ProjectID
    let lastRun: LastRunStatus
    let lastNight: NightRecord?
    let jobs: [(act: Act, state: LaunchAgentJobState)]
    /// The sleep intervals overlapping any of the examined Night windows.
    let sleepIntervals: [SleepInterval]
    /// True when ``SleepHistorySource`` returned nil — the sleep and wake section reports this
    /// distinctly from "no sleep recorded".
    let sleepHistoryUnavailable: Bool
    let missedNights: [MissedNight]
}

/// The Project's last recorded run, or why there is nothing to report.
enum LastRunStatus: Sendable {
    /// No Journal file exists yet: this Project has never run an Act.
    case noJournal
    /// The Journal exists but could not be opened read-only (`JournalError.schemaBehind` or
    /// `.schemaNewerThanKnown`) — reported, never thrown.
    case journalError(String)
    /// The Journal opened, but no event carries a run id.
    case noRunRecorded
    case run(act: Act, runID: RunID, firstEventAt: Date, ending: LastRunEnding)
}

/// How the last run ended, in the precedence ``Status`` reads events in.
enum LastRunEnding: Sendable {
    case ended
    case idle(ActIdleReason)
    case incomplete(reason: String)
    case stoodDown
    /// No ending event was recorded, but the Act-scoped Lease is still held by this run at `now`.
    case runningNow
    /// No ending event was recorded, and the Lease is not held by this run (a crash, most likely).
    case noEndingRecorded
}
