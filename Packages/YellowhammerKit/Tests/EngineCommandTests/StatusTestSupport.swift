import Config
import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization

/// A fixed answer for `LaunchAgentInspecting`, configured per test — mirrors `RecordingLaunchAgentControl`.
final class StubLaunchAgentInspecting: LaunchAgentInspecting, @unchecked Sendable {
    private struct State {
        var jobInfoByLabel: [String: LaunchctlJobInfo]
        var disabledLabels: Set<String>
    }

    private let storage: Mutex<State>

    init(jobInfoByLabel: [String: LaunchctlJobInfo] = [:], disabledLabels: Set<String> = []) {
        storage = Mutex(State(jobInfoByLabel: jobInfoByLabel, disabledLabels: disabledLabels))
    }

    func jobInfo(label: String) async -> LaunchctlJobInfo? {
        storage.withLock { $0.jobInfoByLabel[label] }
    }

    func disabledLabels() async -> Set<String> {
        storage.withLock { $0.disabledLabels }
    }
}

/// A fixed answer for `SleepHistorySource`.
struct StubSleepHistorySource: SleepHistorySource {
    let history: SleepHistory?

    func sleepHistory() async -> SleepHistory? { history }
}

/// UTC Gregorian, so DST never perturbs a fixed clock-time schedule — every `Status` test's shared
/// calendar.
let statusTestCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

func statusTestDate(_ text: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter.date(from: text)!
}

/// Builds a ``Status`` with every seam faked or injected against a temp directory, mirroring `makeDoctor`.
func makeStatus(
    directory: borrowing ConfigurationDirectory,
    homeDirectory: URL = FileManager.default.temporaryDirectory
        .appending(component: "yh-status-home-\(UUID().uuidString)", directoryHint: .isDirectory),
    output: RecordingOutput = RecordingOutput(),
    launchAgents: any LaunchAgentInspecting = StubLaunchAgentInspecting(),
    sleepHistory: any SleepHistorySource = StubSleepHistorySource(history: nil),
    now: Date = statusTestDate("2026-09-24 10:00:00 +0000"),
    calendar: Calendar = statusTestCalendar,
    projectFilter: ProjectID? = nil,
    examinedNights: Int = 7
) -> Status {
    Status(
        configurationDirectory: directory.url,
        homeDirectory: homeDirectory,
        output: { output.record($0) },
        launchAgents: launchAgents,
        sleepHistory: sleepHistory,
        now: now,
        calendar: calendar,
        projectFilter: projectFilter,
        examinedNights: examinedNights
    )
}

/// Records one Night directly via the Journal's own low-level API (claim the Act-scoped Lease, open
/// the Night, optionally close it) at chosen timestamps — precise enough for `yh status`'s scenarios,
/// unlike driving a full `EngineInvocation`.
@discardableResult
func recordNight(
    in journal: JournalStore, nightStart: NightStart, act: Act = .author, mode: NightMode = .real,
    openedAt: Date, closeReason: NightCloseReason? = nil, closedAt: Date? = nil
) throws -> NightRecord {
    let runID = RunID()
    _ = try journal.claimActLease(act: act, runID: runID, mode: mode, now: openedAt)
    let opening = try journal.openNight(nightStart: nightStart, mode: mode, act: act, runID: runID, now: openedAt)
    guard let closeReason else { return opening.night }
    let closingAt = closedAt ?? openedAt
    // Refreshes the lease first: `closedAt` can be far enough past `openedAt` to have crossed the
    // lease's TTL, and `closeNight` revalidates it before writing.
    _ = try journal.claimActLease(act: act, runID: runID, mode: mode, now: closingAt)
    return try journal.closeNight(id: opening.night.id, reason: closeReason, act: act, runID: runID, now: closingAt)
}

/// Creates an empty LaunchAgent plist at the path `Status` checks for installation, so a job's state
/// can move past `.notInstalled`.
func installLaunchAgentPlist(homeDirectory: URL, projectID: ProjectID, act: Act) throws {
    let label = Status.launchAgentLabel(projectID: projectID, act: act)
    let directory = homeDirectory.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appending(component: "\(label).plist", directoryHint: .notDirectory))
}

/// Writes a LaunchAgent log file with `contents`, then sets its modification date — evidence a
/// pre-initialization crash can be read from.
func writeLaunchAgentLog(
    homeDirectory: URL, projectID: ProjectID, act: Act, contents: String, modifiedAt: Date
) throws {
    let directory = homeDirectory.appending(components: "Library", "Logs", "Yellowhammer", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(component: "\(projectID.rawValue).\(act.rawValue).log", directoryHint: .notDirectory)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt], ofItemAtPath: url.path(percentEncoded: false)
    )
}

/// All three Acts' LaunchAgents installed and reporting `loaded`, so `noRunnableJob` never preempts a
/// scenario that is testing something else.
func makeAllJobsLoaded(homeDirectory: URL, projectID: ProjectID) throws -> StubLaunchAgentInspecting {
    var jobInfoByLabel: [String: LaunchctlJobInfo] = [:]
    for act in Act.allCases {
        try installLaunchAgentPlist(homeDirectory: homeDirectory, projectID: projectID, act: act)
        let label = Status.launchAgentLabel(projectID: projectID, act: act)
        jobInfoByLabel[label] = LaunchctlJobInfo(runs: 1, lastExitCode: 0)
    }
    return StubLaunchAgentInspecting(jobInfoByLabel: jobInfoByLabel)
}
