import Domain
import Foundation
import Testing

@testable import Journal

// The build Act's own five events (roadmap P8.1) round-trip here, split out of
// EventEncodingTests.swift to keep that file under the length limit.

private struct BuildActEventFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-buildact-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let buildActEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test("expiredCardLeasesSwept event round-trips, empty and non-empty")
func expiredCardLeasesSweptRoundTrips() throws {
    let fixture = try BuildActEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .expiredCardLeasesSwept(cycleID: 3, reclaimedCardIDs: [1, 2]), act: .build, runID: run, now: buildActEpoch
    )
    try journal.append(
        .expiredCardLeasesSwept(cycleID: 3, reclaimedCardIDs: []), act: .build, runID: run, now: buildActEpoch
    )
    let records = try journal.events(ofType: .expiredCardLeasesSwept)

    #expect(records.count == 2)
    #expect(records[0].event == .expiredCardLeasesSwept(cycleID: 3, reclaimedCardIDs: [1, 2]))
    #expect(records[1].event == .expiredCardLeasesSwept(cycleID: 3, reclaimedCardIDs: []))
}

@Test("boardStateReposted event round-trips")
func boardStateRepostedRoundTrips() throws {
    let fixture = try BuildActEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.boardStateReposted(cards: 4), act: .build, runID: run, now: buildActEpoch)
    let records = try journal.events(ofType: .boardStateReposted)

    #expect(records.count == 1)
    #expect(records[0].event == .boardStateReposted(cards: 4))
}

@Test("repoLanesDerived event round-trips, empty and non-empty")
func repoLanesDerivedRoundTrips() throws {
    let fixture = try BuildActEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .repoLanesDerived(cycleID: 5, lanes: ["backend", "mobile"]), act: .build, runID: run, now: buildActEpoch
    )
    try journal.append(
        .repoLanesDerived(cycleID: 5, lanes: []), act: .build, runID: run, now: buildActEpoch
    )
    let records = try journal.events(ofType: .repoLanesDerived)

    #expect(records.count == 2)
    #expect(records[0].event == .repoLanesDerived(cycleID: 5, lanes: ["backend", "mobile"]))
    #expect(records[1].event == .repoLanesDerived(cycleID: 5, lanes: []))
}

@Test("repoLaneStarted event round-trips")
func repoLaneStartedRoundTrips() throws {
    let fixture = try BuildActEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.repoLaneStarted(repository: "backend", cards: 2), act: .build, runID: run, now: buildActEpoch)
    let records = try journal.events(ofType: .repoLaneStarted)

    #expect(records.count == 1)
    #expect(records[0].event == .repoLaneStarted(repository: "backend", cards: 2))
}

@Test("repoLaneEnded event round-trips, with and without a failure")
func repoLaneEndedRoundTrips() throws {
    let fixture = try BuildActEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .repoLaneEnded(repository: "backend", cardsRun: 2, failure: nil), act: .build, runID: run, now: buildActEpoch
    )
    try journal.append(
        .repoLaneEnded(repository: "mobile", cardsRun: 0, failure: "engine fault"),
        act: .build, runID: run, now: buildActEpoch
    )
    let records = try journal.events(ofType: .repoLaneEnded)

    #expect(records.count == 2)
    #expect(records[0].event == .repoLaneEnded(repository: "backend", cardsRun: 2, failure: nil))
    #expect(records[1].event == .repoLaneEnded(repository: "mobile", cardsRun: 0, failure: "engine fault"))
}

@Test("laneHoleRecorded event round-trips, for both hole states (P8.9)")
func laneHoleRecordedRoundTrips() throws {
    let fixture = try BuildActEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .laneHoleRecorded(cardID: 7, issueID: "BACK-1", repository: "backend", state: .blocked),
        act: .build, runID: run, now: buildActEpoch
    )
    try journal.append(
        .laneHoleRecorded(cardID: 8, issueID: "BACK-2", repository: "backend", state: .waitingOnYou),
        act: .build, runID: run, now: buildActEpoch
    )
    let records = try journal.events(ofType: .laneHoleRecorded)

    #expect(records.count == 2)
    #expect(records[0].event == .laneHoleRecorded(cardID: 7, issueID: "BACK-1", repository: "backend", state: .blocked))
    #expect(
        records[1].event
            == .laneHoleRecorded(cardID: 8, issueID: "BACK-2", repository: "backend", state: .waitingOnYou)
    )
}
