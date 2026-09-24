import Config
import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

/// End-to-end `yh status` "last run" scenarios, driven through the Journal's own low-level API at
/// chosen timestamps.
@Suite("Status: last run")
struct StatusLastRunTests {
    private static let projectID = ProjectID(rawValue: "alpha")!
    private static let nightStart = NightStart(rawValue: "2026-09-23")!
    private static let runStart = statusTestDate("2026-09-23 23:00:00 +0000")
    private static let now = statusTestDate("2026-09-23 23:05:00 +0000")

    private static func openedNight(in journal: JournalStore, runID: RunID, act: Act = .build) throws -> NightRecord {
        _ = try journal.claimActLease(act: act, runID: runID, mode: .real, now: runStart)
        let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: act, runID: runID, now: runStart)
        try journal.append(.actStarted, act: act, runID: runID, nightID: opening.night.id, now: runStart)
        return opening.night
    }

    @Test("No Journal: this Project has never run an Act")
    func noJournal() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        guard case .noJournal = report.projectStatuses.first?.lastRun else {
            Issue.record("expected noJournal, got \(String(describing: report.projectStatuses.first?.lastRun))")
            return
        }
    }

    @Test("ActEnded reads back as ended")
    func ended() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        let runID = RunID()
        let night = try Self.openedNight(in: journal, runID: runID)
        try journal.append(
            .actEnded, act: .build, runID: runID, nightID: night.id, now: Self.runStart.addingTimeInterval(30)
        )

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        let lastRun = report.projectStatuses.first?.lastRun
        guard case .run(let act, let recordedRunID, _, .ended) = lastRun else {
            Issue.record("expected .run(..., ending: .ended), got \(String(describing: lastRun))")
            return
        }
        #expect(act == .build)
        #expect(recordedRunID == runID)
    }

    @Test("ActIdle reads back as idle with its reason")
    func idle() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        let runID = RunID()
        let night = try Self.openedNight(in: journal, runID: runID)
        try journal.append(
            .actIdle(reason: .noFeatureInFlight), act: .build, runID: runID, nightID: night.id,
            now: Self.runStart.addingTimeInterval(30)
        )

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        let lastRun = report.projectStatuses.first?.lastRun
        guard case .run(_, _, _, .idle(let reason)) = lastRun else {
            Issue.record("expected .run(..., ending: .idle), got \(String(describing: lastRun))")
            return
        }
        #expect(reason == .noFeatureInFlight)
    }

    @Test("ActIncomplete reads back as incomplete with its reason")
    func incomplete() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        let runID = RunID()
        let night = try Self.openedNight(in: journal, runID: runID)
        try journal.append(
            .actIncomplete(reason: "board unreachable"), act: .build, runID: runID, nightID: night.id,
            now: Self.runStart.addingTimeInterval(30)
        )

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        let lastRun = report.projectStatuses.first?.lastRun
        guard case .run(_, _, _, .incomplete(let reason)) = lastRun else {
            Issue.record("expected .run(..., ending: .incomplete), got \(String(describing: lastRun))")
            return
        }
        #expect(reason == "board unreachable")
    }

    @Test("A held, unexpired Lease with no terminal event reads back as running now")
    func runningNow() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        let runID = RunID()
        _ = try Self.openedNight(in: journal, runID: runID)
        // `now` (23:05) is well inside the Lease's 10-minute TTL from `runStart` (23:00): still held.

        let status = makeStatus(directory: directory, now: Self.now)
        let report = await status.run()

        let lastRun = report.projectStatuses.first?.lastRun
        guard case .run(_, _, _, .runningNow) = lastRun else {
            Issue.record("expected .run(..., ending: .runningNow), got \(String(describing: lastRun))")
            return
        }
    }

    @Test("No terminal event and an expired Lease reads back as no ending recorded")
    func noEndingRecorded() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        let runID = RunID()
        _ = try Self.openedNight(in: journal, runID: runID)
        let farAfterExpiry = Self.runStart.addingTimeInterval(3_600)

        let status = makeStatus(directory: directory, now: farAfterExpiry)
        let report = await status.run()

        let lastRun = report.projectStatuses.first?.lastRun
        guard case .run(_, _, _, .noEndingRecorded) = lastRun else {
            Issue.record("expected .run(..., ending: .noEndingRecorded), got \(String(describing: lastRun))")
            return
        }
    }

    @Test("`yh status` never creates the Journal it did not find")
    func missingJournalNeverCreated() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journalURL = JournalStore.defaultFileURL(configurationDirectory: directory.url, id: Self.projectID)

        let status = makeStatus(directory: directory, now: Self.now)
        _ = await status.run()

        #expect(!FileManager.default.fileExists(atPath: journalURL.path(percentEncoded: false)))
    }
}
