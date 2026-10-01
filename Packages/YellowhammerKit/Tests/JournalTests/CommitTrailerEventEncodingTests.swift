import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// graph-execution/run-a-card: encode/decode round-trips for the two commit-trailer events and the
// per-Card read of them. Split out to keep EventEncodingTests.swift under the length limit,
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

@Test("cardCommitTrailerMissing event round-trips")
func cardCommitTrailerMissingRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let event = JournalEvent.cardCommitTrailerMissing(
        cardID: 7, issueID: "ENG-7", attemptID: 3, commit: String(repeating: "a", count: 40)
    )
    try journal.append(event, act: .build, runID: RunID(), now: epoch)
    let records = try journal.events(ofType: .cardCommitTrailerMissing)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("cardCommitTrailersUnread event round-trips")
func cardCommitTrailersUnreadRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let event = JournalEvent.cardCommitTrailersUnread(
        cardID: 7, issueID: "ENG-7", attemptID: 3, commit: "deadbeef", reason: "unknown revision"
    )
    try journal.append(event, act: .build, runID: RunID(), now: epoch)
    let records = try journal.events(ofType: .cardCommitTrailersUnread)

    #expect(records.count == 1)
    #expect(records[0].event == event)
}

@Test("commitsRecordedMissingTrailer returns only that Card's missing-trailer commits")
func commitsRecordedMissingTrailerFiltersByCard() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let events: [JournalEvent] = [
        .cardCommitTrailerMissing(cardID: 7, issueID: "ENG-7", attemptID: 3, commit: "aaa"),
        .cardCommitTrailerMissing(cardID: 7, issueID: "ENG-7", attemptID: 4, commit: "bbb"),
        .cardCommitTrailerMissing(cardID: 8, issueID: "ENG-8", attemptID: 5, commit: "ccc"),
        .cardCommitTrailersUnread(cardID: 7, issueID: "ENG-7", attemptID: 4, commit: "ddd", reason: "gone")
    ]
    for event in events {
        try journal.append(event, act: .build, runID: run, now: epoch)
    }

    #expect(try journal.commitsRecordedMissingTrailer(cardID: 7) == ["aaa", "bbb"])
    #expect(try journal.commitsRecordedMissingTrailer(cardID: 8) == ["ccc"])
    #expect(try journal.commitsRecordedMissingTrailer(cardID: 9).isEmpty)
}
