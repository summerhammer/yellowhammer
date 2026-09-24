import Config
import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

/// End-to-end `yh status` scenarios, each staged so exactly one `MissedNightCause` should be
/// diagnosed — the roadmap's own done-when for P13.4.
@Suite("Status: missed Night diagnosis")
struct StatusMissedNightsTests {
    private static let projectID = ProjectID(rawValue: "alpha")!
    /// The most recent ended Night window at `now` (night_start/night_end default 22:00/06:00).
    private static let now = statusTestDate("2026-09-24 10:00:00 +0000")
    private static let windowStart = statusTestDate("2026-09-23 22:00:00 +0000")

    @Test("Pre-initialization crash from a pre-Night ActIncomplete event")
    func preInitCrashFromJournalEvent() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        try journal.append(
            .actIncomplete(reason: "could not read config.toml"), act: .author, runID: RunID(), nightID: nil,
            now: Self.windowStart.addingTimeInterval(300)
        )

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        #expect(missed.count == 1)
        guard case .preInitializationCrash(let evidence) = missed[0].cause else {
            Issue.record("expected preInitializationCrash, got \(missed[0].cause)")
            return
        }
        #expect(evidence.contains { $0.contains("could not read config.toml") })
    }

    @Test("Pre-initialization crash from a LaunchAgent log file modified inside the window")
    func preInitCrashFromLogFile() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-status-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try writeLaunchAgentLog(
            homeDirectory: homeDirectory, projectID: Self.projectID, act: .author,
            contents: "starting\nfatal: could not resolve HEAD\n",
            modifiedAt: Self.windowStart.addingTimeInterval(600)
        )

        let status = makeStatus(directory: directory, homeDirectory: homeDirectory, now: Self.now)
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        #expect(missed.count == 1)
        guard case .preInitializationCrash(let evidence) = missed[0].cause else {
            Issue.record("expected preInitializationCrash, got \(missed[0].cause)")
            return
        }
        #expect(evidence.contains { $0.contains("fatal: could not resolve HEAD") })
    }

    @Test("An invalid Project file gets its own section, never inspected as a Journal/launchd Project")
    func invalidProjectFileGetsItsOwnSection() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeProjectFile(id: "broken", "not valid toml [[[")

        let output = RecordingOutput()
        let status = makeStatus(directory: directory, output: output, now: Self.now)
        let report = await status.run()

        #expect(report.projectStatuses.isEmpty)
        #expect(report.invalidProjectStatuses.count == 1)
        #expect(report.invalidProjectStatuses[0].file.hasSuffix("broken.toml"))
        #expect(output.lines.contains { $0.contains("pre-initialization crash") })
    }

    @Test("No runnable job when every LaunchAgent is not installed")
    func noRunnableJobAllNotInstalled() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        #expect(missed.count == 1)
        guard case .noRunnableJob(let jobs) = missed[0].cause else {
            Issue.record("expected noRunnableJob, got \(missed[0].cause)")
            return
        }
        #expect(jobs == [.author: .notInstalled, .build: .notInstalled, .land: .notInstalled])
    }

    @Test("No runnable job from a mix of disabled and not loaded")
    func noRunnableJobMixed() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-status-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        for act in Act.allCases {
            try installLaunchAgentPlist(homeDirectory: homeDirectory, projectID: Self.projectID, act: act)
        }
        let authorLabel = Status.launchAgentLabel(projectID: Self.projectID, act: .author)
        let launchAgents = StubLaunchAgentInspecting(jobInfoByLabel: [:], disabledLabels: [authorLabel])

        let status = makeStatus(
            directory: directory, homeDirectory: homeDirectory, launchAgents: launchAgents, now: Self.now
        )
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        guard case .noRunnableJob(let jobs) = missed[0].cause else {
            Issue.record("expected noRunnableJob, got \(missed[0].cause)")
            return
        }
        #expect(jobs == [.author: .disabled, .build: .notLoaded, .land: .notLoaded])
    }

    @Test("Asleep when a sleep interval covers every firing")
    func asleepCoversEveryFiring() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-status-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let launchAgents = try makeAllJobsLoaded(homeDirectory: homeDirectory, projectID: Self.projectID)
        let interval = SleepInterval(
            start: statusTestDate("2026-09-23 21:00:00 +0000"), end: statusTestDate("2026-09-24 07:00:00 +0000")
        )
        let sleepHistory = StubSleepHistorySource(
            history: SleepHistory(intervals: [interval], coverageStart: statusTestDate("2026-09-23 00:00:00 +0000"))
        )

        let status = makeStatus(
            directory: directory, homeDirectory: homeDirectory, launchAgents: launchAgents,
            sleepHistory: sleepHistory, now: Self.now
        )
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        #expect(missed.count == 1)
        #expect(missed[0].cause == .asleep([interval]))
    }

    @Test("Undiagnosed with sleepHistoryReachesBack true when nothing explains it")
    func undiagnosedReachesBack() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-status-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let launchAgents = try makeAllJobsLoaded(homeDirectory: homeDirectory, projectID: Self.projectID)
        let sleepHistory = StubSleepHistorySource(
            history: SleepHistory(intervals: [], coverageStart: statusTestDate("2026-09-23 00:00:00 +0000"))
        )

        let status = makeStatus(
            directory: directory, homeDirectory: homeDirectory, launchAgents: launchAgents,
            sleepHistory: sleepHistory, now: Self.now
        )
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        #expect(missed[0].cause == .undiagnosed(sleepHistoryReachesBack: true))
    }

    @Test("Undiagnosed with sleepHistoryReachesBack false when there is no sleep history")
    func undiagnosedNoSleepHistory() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-status-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let launchAgents = try makeAllJobsLoaded(homeDirectory: homeDirectory, projectID: Self.projectID)

        let status = makeStatus(
            directory: directory, homeDirectory: homeDirectory, launchAgents: launchAgents, now: Self.now
        )
        let report = await status.run()

        let missed = try #require(report.projectStatuses.first?.missedNights)
        #expect(missed[0].cause == .undiagnosed(sleepHistoryReachesBack: false))
    }

    @Test("A recorded Night for the examined window is not reported missed")
    func recordedNightIsNotMissed() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        try recordNight(
            in: journal, nightStart: NightStart(rawValue: "2026-09-23")!, act: .land,
            openedAt: Self.windowStart.addingTimeInterval(60), closeReason: .nightEnd,
            closedAt: Self.windowStart.addingTimeInterval(28_800)
        )

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        #expect(report.projectStatuses.first?.missedNights.isEmpty == true)
    }

    @Test("A brand-new Journal with one Night does not report Nights before it")
    func brandNewJournalDoesNotReportEarlierNights() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        // The Project's very first Night is the one the examined window falls on; four earlier
        // windows (09-22 back to 09-19) are also ended within `examinedNights: 5`, but none of them
        // should be reported missed — the Project did not exist yet.
        try recordNight(
            in: journal, nightStart: NightStart(rawValue: "2026-09-23")!, act: .land,
            openedAt: Self.windowStart.addingTimeInterval(60), closeReason: .nightEnd,
            closedAt: Self.windowStart.addingTimeInterval(28_800)
        )

        let status = makeStatus(directory: directory, now: Self.now, examinedNights: 5)
        let report = await status.run()

        #expect(report.projectStatuses.first?.missedNights.isEmpty == true)
    }
}
