import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P8.11: encode/decode round-trips for the two rehearsal-boundary events (system-overview,
// Environment Differences). Split out to keep EventEncodingTests.swift under the length limit,
// following RouteRetryEventEncodingTests.swift's pattern.

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

@Test("agentCLIProcessSpawned event round-trips")
func agentCLIProcessSpawnedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let event = JournalEvent.agentCLIProcessSpawned(
        cardID: 7, issueID: "ENG-7", attemptID: 3, pass: .worker, cli: "claude"
    )
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .agentCLIProcessSpawned)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("rehearsalFixtureAnswered event round-trips")
func rehearsalFixtureAnsweredRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let event = JournalEvent.rehearsalFixtureAnswered(
        cardID: 7, issueID: "ENG-7", attemptID: 3, pass: .architect, fixture: "architect-planned.json"
    )
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .rehearsalFixtureAnswered)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("agentCLIProcessSpawned with a malformed pass is unreadable")
func agentCLIProcessSpawnedMalformedPassIsUnreadable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO event (type, occurred_at, payload) VALUES (?, ?, ?)",
            arguments: [
                "AgentCLIProcessSpawned", JournalStore.timestamp(epoch),
                #"{"attempt_id":"3","card_id":"7","cli":"claude","issue_id":"ENG-7","pass":"not-a-pass"}"#
            ]
        )
    }

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        try journal.events()
    }
}
