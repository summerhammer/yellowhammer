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
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@Test("events() returns events in append order")
func eventsOrderedByID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.actStarted, act: .author, runID: run, now: epoch)
    let fetchFailed = JournalEvent.mainlineFetchFailed(
        repository: "backend", reason: "failed"
    )
    try journal.append(
        fetchFailed, act: .author, runID: run, now: epoch.addingTimeInterval(1)
    )
    try journal.append(.actEnded, act: .author, runID: run, now: epoch.addingTimeInterval(2))

    let records = try journal.events()
    #expect(records.count == 3)
    #expect(records[0].event == .actStarted)
    #expect(records[1].type == .mainlineFetchFailed)
    #expect(records[2].event == .actEnded)
}

@Test("events(ofType:) filters by type")
func eventsFilterByType() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.actStarted, act: .author, runID: run)
    try journal.append(.mainlineFetchFailed(repository: "backend", reason: "failed"), act: .author, runID: run)
    try journal.append(.actEnded, act: .author, runID: run)

    let started = try journal.events(ofType: .actStarted)
    #expect(started.count == 1)
    #expect(started[0].event == .actStarted)

    let failures = try journal.events(ofType: .mainlineFetchFailed)
    #expect(failures.count == 1)
}

@Test("The stored type column contains spec names")
func storedTypeColumnsMatchSpec() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.mainlineFetchFailed(repository: "repo", reason: "reason"), act: .build, runID: run, now: epoch)

    try journal.read { db in
        let typeRaw: String? = try String.fetchOne(db, sql: "SELECT type FROM event WHERE id = 1")
        #expect(typeRaw == "MainlineFetchFailed")
    }
}

@Test("Append-only: UPDATE fails with 'event is append-only'")
func appendOnlyUpdateFails() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.append(.actStarted, act: .author, runID: RunID())

    #expect(throws: (any Error).self) {
        try journal.write { db in
            try db.execute(sql: "UPDATE event SET type = 'ActEnded' WHERE id = 1")
        }
    }
}

@Test("Append-only: DELETE fails with 'event is append-only'")
func appendOnlyDeleteFails() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.append(.actStarted, act: .author, runID: RunID())

    #expect(throws: (any Error).self) {
        try journal.write { db in
            try db.execute(sql: "DELETE FROM event WHERE id = 1")
        }
    }
}

@Test("Taking over an expired lease appends exactly one LeaseReclaimed event")
func expiredLeaseReclaimAppendsOneEvent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let dead = RunID()
    let next = RunID()

    _ = try journal.claimActLease(act: .author, runID: dead, mode: .real, now: epoch)

    try journal.claimActLease(act: .build, runID: next, mode: .real, now: epoch.addingTimeInterval(600))

    let events = try journal.events()
    let reclaimEvents = events.filter { event in
        if case .leaseReclaimed = event.event { return true }
        return false
    }

    #expect(reclaimEvents.count == 1)
    let reclaim = reclaimEvents[0]
    guard case .leaseReclaimed(let readRunID, let readAct, let readExpiredAt) = reclaim.event else {
        Issue.record("Event is not leaseReclaimed")
        return
    }
    #expect(readRunID == dead)
    #expect(readAct == .author)
    #expect(readExpiredAt == epoch.addingTimeInterval(600))
    #expect(reclaim.act == .build)
    #expect(reclaim.runID == next)
}

@Test("A first claim appends no LeaseReclaimed event")
func firstClaimNoEvent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.claimActLease(act: .author, runID: RunID(), mode: .real, now: epoch)

    let events = try journal.events()
    let reclaimEvents = events.filter { event in
        if case .leaseReclaimed = event.event { return true }
        return false
    }

    #expect(reclaimEvents.isEmpty)
}

@Test("A same-run re-claim appends no LeaseReclaimed event")
func sameRunReclaimNoEvent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch.addingTimeInterval(30))

    let events = try journal.events()
    let reclaimEvents = events.filter { event in
        if case .leaseReclaimed = event.event { return true }
        return false
    }

    #expect(reclaimEvents.isEmpty)
}

@Test("No event log spans Projects: each Project's Journal is isolated")
func eventLogIsPerProject() throws {
    let alpha = try JournalFixture(project: "alpha")
    let beta = try JournalFixture(project: "beta")

    let alphaJournal = try alpha.open()
    let betaJournal = try beta.open()

    let run = RunID()

    try alphaJournal.append(.actStarted, act: .author, runID: run)
    try betaJournal.append(.actEnded, act: .build, runID: run)

    let alphaEvents = try alphaJournal.events()
    let betaEvents = try betaJournal.events()

    #expect(alphaEvents.count == 1)
    #expect(alphaEvents[0].event == .actStarted)

    #expect(betaEvents.count == 1)
    #expect(betaEvents[0].event == .actEnded)
}

@Test("Corrupt row with missing required payload field throws eventUnreadable")
func corruptPayloadThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    // Insert a corrupt actIncomplete event with NULL payload
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO event (type, occurred_at, payload) VALUES ('ActIncomplete', ?, NULL)",
            arguments: [JournalStore.timestamp(epoch)]
        )
    }

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        _ = try journal.events()
    }
}

@Test("An event type this build does not know is skipped by events() and pulseEvents, known rows still read")
func unknownTypeIsSkipped() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    _ = try journal.claimActLease(act: .build, runID: run, mode: .real, now: epoch)
    let nightStart = try #require(NightStart(rawValue: "2026-09-12"))
    let night = try journal.openNight(nightStart: nightStart, mode: .real, act: .build, runID: run, now: epoch).night.id
    let baseline = try journal.events().count

    try journal.append(.actStarted, act: .build, runID: run, nightID: night, now: epoch)
    // A row written by a newer `yh`, between two known events.
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO event (night_id, type, occurred_at, payload)
            VALUES (?, 'SomeFutureEvent', ?, '{"k":"v"}')
            """,
            arguments: [night, JournalStore.timestamp(epoch)]
        )
    }
    try journal.append(.actEnded, act: .build, runID: run, nightID: night, now: epoch)

    // Opening the Night wrote its own events; the two appended around the unknown row follow them.
    let all = try journal.events()
    #expect(all.count == baseline + 2)
    #expect(all.suffix(2).map(\.event) == [.actStarted, .actEnded])
    let pulse = try journal.pulseEvents(nightID: night, unstampedFailuresSince: epoch)
    #expect(pulse.suffix(2).map(\.event) == [.actStarted, .actEnded])}
