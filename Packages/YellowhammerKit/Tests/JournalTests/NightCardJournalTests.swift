import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// shift-scheduling/open-and-close-the-night-card (P5.7): recordNightCard and
// recordAuthoringNoWorkAvailable, split out of NightTests.swift to keep it under the file length limit.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-night-card-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let nightStart = NightStart(rawValue: "2026-09-15")!

@Test("recordNightCard sets the issue id and appends nightCardOpened")
func recordNightCardSetsIssueID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

    let updated = try journal.recordNightCard(
        id: opening.night.id, issueID: "NIGHT-1", act: .author, runID: run, now: epoch
    )

    #expect(updated.nightCardIssueID == "NIGHT-1")
    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .nightCardOpened])
}

@Test("recordNightCard with the same issue id twice is a no-op")
func recordNightCardSameIDIsNoOp() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    _ = try journal.recordNightCard(id: opening.night.id, issueID: "NIGHT-1", act: .author, runID: run, now: epoch)

    let updated = try journal.recordNightCard(
        id: opening.night.id, issueID: "NIGHT-1", act: .author, runID: run, now: epoch
    )

    #expect(updated.nightCardIssueID == "NIGHT-1")
    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .nightCardOpened])
}

@Test("recordNightCard with a different issue id throws nightCardAlreadyRecorded")
func recordNightCardDifferentIDThrows() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    _ = try journal.recordNightCard(id: opening.night.id, issueID: "NIGHT-1", act: .author, runID: run, now: epoch)

    await #expect(throws: JournalError.nightCardAlreadyRecorded(id: opening.night.id, issueID: "NIGHT-1")) {
        try journal.recordNightCard(id: opening.night.id, issueID: "NIGHT-2", act: .author, runID: run, now: epoch)
    }
}

@Test("recordAuthoringNoWorkAvailable sets the idle verdict and appends the event")
func recordAuthoringNoWorkAvailableSetsIdle() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

    let updated = try journal.recordAuthoringNoWorkAvailable(
        nightID: opening.night.id, act: .author, runID: run, now: epoch
    )

    #expect(updated.verdict == .idle)
    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .authoringNoWorkAvailable])
}

@Test("recordAuthoringNoWorkAvailable on a closed Night throws nightAlreadyClosed")
func recordAuthoringNoWorkAvailableOnClosedNightThrows() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    _ = try journal.closeNight(id: opening.night.id, reason: .nightEnd, act: .land, runID: run, now: epoch)

    await #expect(throws: JournalError.nightAlreadyClosed(id: opening.night.id)) {
        try journal.recordAuthoringNoWorkAvailable(nightID: opening.night.id, act: .author, runID: run, now: epoch)
    }
}

@Test("A fresh Night decodes with a nil verdict")
func freshNightHasNilVerdict() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

    #expect(opening.night.verdict == nil)
}

@Test("nightCardOpened event round-trips")
func nightCardOpenedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.append(.nightCardOpened(issueID: "NIGHT-1"), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .nightCardOpened(let readIssueID) = records[0].event else {
        Issue.record("Event is not nightCardOpened")
        return
    }
    #expect(readIssueID == "NIGHT-1")
}

@Test("nightCardCompleted event round-trips")
func nightCardCompletedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.append(.nightCardCompleted(issueID: "NIGHT-1"), act: .land, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .nightCardCompleted(let readIssueID) = records[0].event else {
        Issue.record("Event is not nightCardCompleted")
        return
    }
    #expect(readIssueID == "NIGHT-1")
}

@Test("nightCardCompletionDeferred event round-trips with its entry ids in order")
func nightCardCompletionDeferredRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let event = JournalEvent.nightCardCompletionDeferred(
        issueID: "NIGHT-1", entryIDs: [12, 7], reason: "Linear returned 503"
    )

    _ = try journal.append(event, act: .land, runID: run, now: epoch)
    let records = try journal.events(ofType: .nightCardCompletionDeferred)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("Night Card replacement retains generations,clears stale display metadata and replays atomically")
func replacementRetainsHistory() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let night = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch).night
    _ = try journal.recordNightCard(
        id: night.id, issueID: "old", issueIDForDisplay: "ENG-1", act: .author, runID: run, now: epoch
    )
    _ = try journal.replaceNightCard(
        id: night.id, predecessorIssueID: "old", issueID: "new", act: .author, runID: run, now: epoch
    )
    let replay = try journal.replaceNightCard(
        id: night.id, predecessorIssueID: "old", issueID: "new", act: .author, runID: run, now: epoch
    )
    #expect(replay.nightCardIssueID == "new")
    #expect(replay.nightCardIssueIDForDisplay == nil)
    #expect(try journal.archivedNightCardIssueIDs(nightID: night.id) == ["old"])
    #expect(try journal.events(ofType: .nightCardOpened).count == 2)
    #expect(throws: JournalError.nightCardAlreadyRecorded(id: night.id, issueID: "new")) {
        try journal.replaceNightCard(
            id: night.id, predecessorIssueID: "old", issueID: "stale", act: .author, runID: run, now: epoch
        )
    }
    #expect(try journal.night(id: night.id)?.nightCardIssueID == "new")
}

@Test("A released Act cannot replace its Night Card or append a predecessor")
func replacementRequiresLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    let night = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch).night
    _ = try journal.recordNightCard(id: night.id, issueID: "old", act: .author, runID: run, now: epoch)
    try journal.releaseActLease(runID: run)
    #expect(throws: JournalError.actLeaseLost(runID: run, holder: nil)) {
        try journal.replaceNightCard(
            id: night.id, predecessorIssueID: "old", issueID: "new", act: .author, runID: run, now: epoch
        )
    }
    #expect(try journal.night(id: night.id)?.nightCardIssueID == "old")
    #expect(try journal.archivedNightCardIssueIDs(nightID: night.id).isEmpty)
}
