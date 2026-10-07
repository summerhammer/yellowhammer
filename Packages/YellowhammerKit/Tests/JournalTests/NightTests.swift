import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-night-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@Test("The Journal has the single schema migration")
func migrationIdentifiersAreTheSingleSchema() throws {
    #expect(JournalStore.migrationIdentifiers == ["journal-schema-9"])
}

@Test("Opening a Night records it and returns isFirstAct: true")
func openNightRecordsAndReturnsFirstAct() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)

    #expect(opening.isFirstAct == true)
    #expect(opening.night.nightStart == nightStart)
    #expect(opening.night.state == .opened)
    #expect(opening.night.mode == .real)
    #expect(opening.night.openedAt == epoch)
    #expect(opening.night.completedAt == nil)
    #expect(opening.night.closeReason == nil)
    #expect(opening.openedAndDied.isEmpty)

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened])
}

@Test("Opening a Night twice with same nightStart returns existing without re-opening")
func openingNightTwiceReturnsExisting() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let opening1 = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run1, now: epoch)
    try journal.releaseActLease(runID: run1)

    _ = try journal.claimActLease(act: .build, runID: run2, mode: .real, now: epoch.addingTimeInterval(60))
    let opening2 = try journal.openNight(
        nightStart: nightStart, mode: .real, act: .build, runID: run2, now: epoch.addingTimeInterval(60)
    )

    #expect(opening2.isFirstAct == false)
    #expect(opening2.night.id == opening1.night.id)
    #expect(opening2.openedAndDied.isEmpty)

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened])
}

@Test("Opening a Night requires the Act lease")
func openingNightRequiresLease() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    await #expect(throws: JournalError.actLeaseLost(runID: run, holder: nil)) {
        try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    }
}

@Test("Closing a Night sets state to closed and records close reason")
func closingNightSetsStateAndReason() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    let closed = try journal.closeNight(
        id: opening.night.id, reason: .nightEnd, act: .land, runID: run, now: epoch.addingTimeInterval(10)
    )

    #expect(closed.state == .closed)
    #expect(closed.closeReason == .nightEnd)
    #expect(closed.completedAt == epoch.addingTimeInterval(10))

    let events = try journal.events()
    #expect(events.map(\.type) == [.nightOpened, .nightClosed])
}

@Test("Closing a Night again throws nightAlreadyClosed")
func closingNightAgainThrows() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    _ = try journal.closeNight(
        id: opening.night.id, reason: .nightEnd, act: .land, runID: run, now: epoch.addingTimeInterval(10)
    )

    await #expect(throws: JournalError.nightAlreadyClosed(id: opening.night.id)) {
        try journal.closeNight(
            id: opening.night.id, reason: .nightEnd, act: .land, runID: run, now: epoch.addingTimeInterval(20)
        )
    }
}

@Test("Closing a non-existent Night throws nightUnknown")
func closingUnknownNightThrows() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    await #expect(throws: JournalError.nightUnknown(id: 999)) {
        try journal.closeNight(id: 999, reason: .nightEnd, act: .land, runID: run, now: epoch)
    }
}

@Test("Opening a new Night sweeps opened-and-died Nights with event per swept")
func openingNewNightSweepsOpenedAndDied() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-09-14")!
    let opening1 = try journal.openNight(nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch)
    try journal.releaseActLease(runID: run1)

    _ = try journal.claimActLease(act: .author, runID: run2, mode: .real, now: epoch.addingTimeInterval(86400))
    let opening2 = try journal.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: run2, now: epoch.addingTimeInterval(86400)
    )

    #expect(opening2.openedAndDied.count == 1)
    #expect(opening2.openedAndDied[0].id == opening1.night.id)
    #expect(opening2.openedAndDied[0].state == .closed)
    #expect(opening2.openedAndDied[0].closeReason == .openedAndDied)

    let events = try journal.events()
    let eventTypes = events.map(\.type)
    #expect(eventTypes == [.nightOpened, .nightOpened, .nightOpenedAndDied])

    let openedAndDiedEvent = events[2]
    #expect(openedAndDiedEvent.nightID == opening2.night.id)
    guard case .nightOpenedAndDied(let sweepNightID, let sweepNightStart) = openedAndDiedEvent.event else {
        Issue.record("Event should be nightOpenedAndDied")
        return
    }
    #expect(sweepNightID == opening1.night.id)
    #expect(sweepNightStart == night1Start)
}

@Test("Opening a new Night does not sweep closed Nights")
func openingNewNightDoesNotSweepClosed() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let night1Start = NightStart(rawValue: "2026-09-14")!
    let opening1 = try journal.openNight(nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch)
    _ = try journal.closeNight(
        id: opening1.night.id, reason: .nightEnd, act: .land, runID: run1, now: epoch.addingTimeInterval(100)
    )
    try journal.releaseActLease(runID: run1)

    _ = try journal.claimActLease(act: .author, runID: run2, mode: .real, now: epoch.addingTimeInterval(86400))
    let opening2 = try journal.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: run2, now: epoch.addingTimeInterval(86400)
    )

    #expect(opening2.openedAndDied.isEmpty)
}

@Test("Opening a Night with existing closed record returns it without reopening")
func openingClosedNightReturnsWithoutReopening() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run1 = RunID()
    let run2 = RunID()
    _ = try journal.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)

    let opening1 = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run1, now: epoch)
    _ = try journal.closeNight(
        id: opening1.night.id, reason: .nightEnd, act: .land, runID: run1, now: epoch.addingTimeInterval(100)
    )
    try journal.releaseActLease(runID: run1)

    _ = try journal.claimActLease(act: .author, runID: run2, mode: .real, now: epoch.addingTimeInterval(200))
    let opening2 = try journal.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: run2, now: epoch.addingTimeInterval(200)
    )

    #expect(opening2.isFirstAct == false)
    #expect(opening2.night.state == .closed)
    #expect(opening2.night.id == opening1.night.id)
}

@Test("currentNight returns the single open Night")
func currentNightReturnsOpen() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)

    #expect(try journal.currentNight() == nil)

    let opening = try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch)
    let current = try journal.currentNight()

    #expect(current?.id == opening.night.id)
}

@Test("Sibling Projects have separate Nights: opening in one does not sweep the other's")
func siblingProjectsHaveSeparateNights() throws {
    let fixtureAlpha = try JournalFixture(project: "alpha")
    let fixtureBeta = try JournalFixture(project: "beta")
    let journalAlpha = try fixtureAlpha.open()
    let journalBeta = try fixtureBeta.open()

    let run1 = RunID()
    let run2 = RunID()
    _ = try journalAlpha.claimActLease(act: .author, runID: run1, mode: .real, now: epoch)
    let nextEvening = epoch.addingTimeInterval(86400)
    _ = try journalBeta.claimActLease(act: .author, runID: run2, mode: .real, now: nextEvening)

    let night1Start = try #require(NightStart(rawValue: "2026-09-14"))
    let opening1 = try journalAlpha.openNight(
        nightStart: night1Start, mode: .real, act: .author, runID: run1, now: epoch
    )
    try journalAlpha.releaseActLease(runID: run1)

    // alpha's Night is left open. beta's next Night neither sees it nor reports it.
    let opening2 = try journalBeta.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: run2, now: nextEvening
    )

    #expect(opening2.openedAndDied.isEmpty)
    #expect(try journalBeta.events().map(\.type) == [.nightOpened])
    #expect(try journalAlpha.events().map(\.type) == [.nightOpened])
    #expect(try journalAlpha.currentNight()?.id == opening1.night.id)

    // alpha's own next Night is what reports it.
    let run3 = RunID()
    _ = try journalAlpha.claimActLease(act: .author, runID: run3, mode: .real, now: nextEvening)
    let opening3 = try journalAlpha.openNight(
        nightStart: nightStart, mode: .real, act: .author, runID: run3, now: nextEvening
    )
    #expect(opening3.openedAndDied.map(\.id) == [opening1.night.id])
    #expect(try journalAlpha.events().map(\.type) == [.nightOpened, .nightOpened, .nightOpenedAndDied])
}

@Test("NightStart rawValue validation")
func nightStartValidation() throws {
    #expect(NightStart(rawValue: "2026-09-15") != nil)
    #expect(NightStart(rawValue: "2026-9-5") == nil)
    #expect(NightStart(rawValue: "2026-13-01") == nil)
    #expect(NightStart(rawValue: "20260915") == nil)
    #expect(NightStart(rawValue: "") == nil)

    let ns = NightStart(rawValue: "2026-09-15")!
    #expect(ns.year == 2026)
    #expect(ns.month == 9)
    #expect(ns.day == 15)
    #expect(ns.description == "2026-09-15")
}

@Test("NightStart init with components")
func nightStartWithComponents() throws {
    let ns = NightStart(year: 2026, month: 9, day: 15)
    #expect(ns != nil)
    #expect(ns?.rawValue == "2026-09-15")

    #expect(NightStart(year: 2026, month: 13, day: 15) == nil)
    #expect(NightStart(year: 2026, month: 9, day: 32) == nil)
}

// recordNightCard, recordAuthoringNoWorkAvailable and the fresh-Night verdict are covered in
// NightCardJournalTests.swift, split out to keep this file under the length limit.

@Test("Schema refuses close_reason outside the allowed set")
func schemaRefusesBadCloseReason() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    await #expect(throws: DatabaseError.self) {
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO night (project_id, night_start, mode, state, opened_at, close_reason)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    journal.projectID.rawValue, "2026-09-15", "real", "closed",
                    JournalStore.timestamp(epoch), "invalid_reason"
                ]
            )
        }
    }
}
