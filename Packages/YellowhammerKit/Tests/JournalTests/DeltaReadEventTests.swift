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
            .appending(component: "yh-delta-events-\(UUID().uuidString)", directoryHint: .isDirectory)
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

// MARK: - Event Round-trip Tests

@Test("cardShelved event round-trips")
func cardShelvedEventRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.append(
        .cardShelved(cardID: 42, issueID: "ISSUE-1", previousState: .blocked),
        act: .author,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .cardShelved)
    #expect(records.count == 1)
    guard case .cardShelved(let cardID, let issueID, let prevState) = records[0].event else {
        Issue.record("Event is not cardShelved")
        return
    }
    #expect(cardID == 42)
    #expect(issueID == "ISSUE-1")
    #expect(prevState == .blocked)
}

@Test("cardReopened event round-trips")
func cardReopenedEventRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.append(
        .cardReopened(cardID: 42, issueID: "ISSUE-1", restoredState: .todo),
        act: .author,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .cardReopened)
    #expect(records.count == 1)
    guard case .cardReopened(let cardID, let issueID, let restoredState) = records[0].event else {
        Issue.record("Event is not cardReopened")
        return
    }
    #expect(cardID == 42)
    #expect(issueID == "ISSUE-1")
    #expect(restoredState == .todo)
}

@Test("cardRestated event round-trips")
func cardRestatedEventRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.append(
        .cardRestated(
            cardID: 42, issueID: "ISSUE-1", journalState: .inProgress, boardState: "In Review"
        ),
        act: .build,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .cardRestated)
    #expect(records.count == 1)
    guard case .cardRestated(let cardID, let issueID, let journalState, let boardState) =
        records[0].event
    else {
        Issue.record("Event is not cardRestated")
        return
    }
    #expect(cardID == 42)
    #expect(issueID == "ISSUE-1")
    #expect(journalState == .inProgress)
    #expect(boardState == "In Review")
}

@Test("cardRemovedFromBoard event round-trips")
func cardRemovedFromBoardEventRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.append(
        .cardRemovedFromBoard(cardID: 42, issueID: "ISSUE-1", how: "archived"),
        act: .build,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .cardRemovedFromBoard)
    #expect(records.count == 1)
    guard case .cardRemovedFromBoard(let cardID, let issueID, let how) = records[0].event else {
        Issue.record("Event is not cardRemovedFromBoard")
        return
    }
    #expect(cardID == 42)
    #expect(issueID == "ISSUE-1")
    #expect(how == "archived")
}

@Test("authoringInvariantBroken event round-trips")
func authoringInvariantBrokenEventRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.append(
        .authoringInvariantBroken(
            cardID: 42, issueID: "ISSUE-1", reason: "cycle not in flight"
        ),
        act: .author,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .authoringInvariantBroken)
    #expect(records.count == 1)
    guard case .authoringInvariantBroken(let cardID, let issueID, let reason) =
        records[0].event
    else {
        Issue.record("Event is not authoringInvariantBroken")
        return
    }
    #expect(cardID == 42)
    #expect(issueID == "ISSUE-1")
    #expect(reason == "cycle not in flight")
}

@Test("deltaReadCompleted event with all counts and optional fields")
func deltaReadCompletedEventRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    let since = Date(timeIntervalSince1970: 1_789_000_000)
    let syncPoint = Date(timeIntervalSince1970: 1_789_100_000)

    _ = try journal.append(
        .deltaReadCompleted(
            objects: 5,
            comments: 10,
            ownComments: 3,
            requests: 2,
            since: since,
            syncPoint: syncPoint
        ),
        act: .build,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .deltaReadCompleted)
    #expect(records.count == 1)
    guard case .deltaReadCompleted(
        let objects, let comments, let ownComments, let requests,
        let readSince, let readSyncPoint
    ) = records[0].event else {
        Issue.record("Event is not deltaReadCompleted")
        return
    }
    #expect(objects == 5)
    #expect(comments == 10)
    #expect(ownComments == 3)
    #expect(requests == 2)
    #expect(readSince == since)
    #expect(readSyncPoint == syncPoint)
}

@Test("deltaReadCompleted event without optional fields round-trips")
func deltaReadCompletedEventWithoutOptionalFields() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.append(
        .deltaReadCompleted(
            objects: 5,
            comments: 10,
            ownComments: 3,
            requests: 2,
            since: nil,
            syncPoint: nil
        ),
        act: .build,
        runID: runID,
        now: epoch
    )

    let records = try journal.events(ofType: .deltaReadCompleted)
    #expect(records.count == 1)
    guard case .deltaReadCompleted(
        let objects, let comments, let ownComments, let requests,
        let readSince, let readSyncPoint
    ) = records[0].event else {
        Issue.record("Event is not deltaReadCompleted")
        return
    }
    #expect(objects == 5)
    #expect(comments == 10)
    #expect(ownComments == 3)
    #expect(requests == 2)
    #expect(readSince == nil)
    #expect(readSyncPoint == nil)
}
