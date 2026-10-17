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

    /// Records `events` in one run of `act` on a fresh Journal and returns how `yh status` reads its ending.
    private func endingText(act: Act = .build, events: [JournalEvent]) async throws -> String {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile()
        try directory.writeValidProjectFile(id: "alpha")
        let journal = try JournalStore.openSeeded(configurationDirectory: directory.url, projectID: Self.projectID)
        let runID = RunID()
        let night = try Self.openedNight(in: journal, runID: runID, act: act)
        for (offset, event) in events.enumerated() {
            try journal.append(
                event, act: act, runID: runID, nightID: night.id,
                now: Self.runStart.addingTimeInterval(Double(offset + 1) * 10)
            )
        }
        let output = RecordingOutput()
        let status = makeStatus(directory: directory, output: output, now: Self.now)
        _ = await status.run()
        let line = output.lines.first { $0.contains("\(act.rawValue) run \(runID.rawValue)") }
        let text = try #require(line)
        return String(try #require(text.split(separator: "started ", maxSplits: 1).last))
            .split(separator: ": ", maxSplits: 1).last.map(String.init) ?? text
    }

    @Test("ActIncomplete reads back as failed with its headline and reason")
    func incomplete() async throws {
        let text = try await endingText(events: [.actIncomplete(reason: "board unreachable")])
        #expect(text == "failed: The build Act could not complete \u{2014} board unreachable")
    }

    @Test("A board-scope ActIncomplete reads back as failed, naming the board scope")
    func boardScopeIncomplete() async throws {
        let text = try await endingText(
            events: [.actIncomplete(reason: "\(ActFailureCause.boardScopePrefix): no Linear project")]
        )
        #expect(text == "failed: The build Act did no work: the board scope is unresolved")
    }

    @Test("A rejected breakdown before ActEnded reads back as failed, never ended")
    func rejectedBreakdownThenEnded() async throws {
        let reason = "Work Card \"T\" (seshes-backend) composes 12,153 UTF-16 code units, over the description "
            + "budget of 10,000: Brief 7,000"
        let text = try await endingText(
            act: .author, events: [.featureBreakdownRejected(name: "Sync", reason: reason), .actEnded]
        )
        #expect(text == "failed: Authoring \u{201C}Sync\u{201D} failed: over the description budget")
    }

    @Test("A failed lane then ActIncomplete reads back as failed at the lane, with its reason")
    func failedLaneThenIncomplete() async throws {
        let text = try await endingText(events: [
            .repoLaneEnded(repository: "backend", cardsRun: 1, failure: "the Check failed"),
            .actIncomplete(reason: "the build Act's lanes failed: backend: the Check failed")
        ])
        #expect(text == "failed: The build Act's backend lane failed \u{2014} the Check failed")
    }

    @Test("A run with no failure still reads back as ended")
    func cleanRunStillEnded() async throws {
        let text = try await endingText(events: [.actEnded])
        #expect(text == "ended")
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
