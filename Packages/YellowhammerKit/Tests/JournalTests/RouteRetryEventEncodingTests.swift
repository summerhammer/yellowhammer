import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Split out of EventEncodingTests.swift to keep that file under the length limit. Round-trips the
// three events route exclusion on retry appends (routing/exclude-tried-routes-on-retry, P7.7).

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
private let routeA = Route(cli: "claude", model: "opus", effort: "high")!

@Test("attemptEnded event round-trips, with route_excluded as a boolean")
func attemptEndedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let event = JournalEvent.attemptEnded(
        cardID: 7, issueID: "ENG-7", attemptID: 3, route: routeA, outcome: "hard failure", routeExcluded: true
    )
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .attemptEnded)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("attemptEnded with a malformed route_excluded is unreadable")
func attemptEndedMalformedBoolIsUnreadable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO event (type, occurred_at, payload) VALUES (?, ?, ?)",
            arguments: [
                "AttemptEnded", JournalStore.timestamp(epoch),
                #"{"attempt_id":"3","card_id":"7","issue_id":"ENG-7","outcome":"hard failure","#
                    + #""route_cli":"claude","route_effort":"high","route_excluded":"maybe","route_model":"opus"}"#
            ]
        )
    }

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        try journal.events()
    }
}

@Test("attemptEnded with an unparsable Route is unreadable")
func attemptEndedMalformedRouteIsUnreadable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO event (type, occurred_at, payload) VALUES (?, ?, ?)",
            arguments: [
                "AttemptEnded", JournalStore.timestamp(epoch),
                #"{"attempt_id":"3","card_id":"7","issue_id":"ENG-7","outcome":"hard failure","#
                    + #""route_cli":"","route_effort":"high","route_excluded":"true","route_model":"opus"}"#
            ]
        )
    }

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        try journal.events()
    }
}

@Test("routeRetried event round-trips, with different_route as a boolean")
func routeRetriedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let event = JournalEvent.routeRetried(
        cardID: 7, issueID: "ENG-7", attemptID: 4, route: routeA, differentRoute: false
    )
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .routeRetried)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("budgetEpochReset event round-trips, naming the epoch it moved from and to")
func budgetEpochResetRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let event = JournalEvent.budgetEpochReset(
        cardID: 7, issueID: "ENG-7", from: 0, to: 1, reason: "Override `claude/-/-` pinned in triage"
    )
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .budgetEpochReset)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("budgetEpochReset with a non-integer epoch is unreadable")
func budgetEpochResetMalformedEpochIsUnreadable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO event (type, occurred_at, payload) VALUES (?, ?, ?)",
            arguments: [
                "BudgetEpochReset", JournalStore.timestamp(epoch),
                #"{"card_id":"7","from_epoch":"zero","issue_id":"ENG-7","reason":"x","to_epoch":"1"}"#
            ]
        )
    }

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        try journal.events()
    }
}
