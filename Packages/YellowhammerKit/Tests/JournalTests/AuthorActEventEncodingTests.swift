import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Split out of EventEncodingTests.swift to keep that file under the length limit. Round-trips the
// author Act's own quiet-Night events (roadmap P9.1): a Feature already in flight, and a predecessor
// Feature not yet landed in every repository.

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

@Test("authoringSkippedFeatureInFlight event round-trips")
func authoringSkippedFeatureInFlightRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.authoringSkippedFeatureInFlight(featureIssueID: "FEAT-1"), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .authoringSkippedFeatureInFlight(let featureIssueID) = records[0].event else {
        Issue.record("Event is not authoringSkippedFeatureInFlight")
        return
    }
    #expect(featureIssueID == "FEAT-1")
}

@Test("authoringPredecessorNotLanded event round-trips, including repository names with commas")
func authoringPredecessorNotLandedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let repositories = ["backend, inc", "mobile"]

    try journal.append(
        .authoringPredecessorNotLanded(featureIssueID: "FEAT-0", repositories: repositories),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .authoringPredecessorNotLanded(let featureIssueID, let readRepositories) = records[0].event else {
        Issue.record("Event is not authoringPredecessorNotLanded")
        return
    }
    #expect(featureIssueID == "FEAT-0")
    #expect(readRepositories == repositories)
}

@Test("authoringPredecessorNotLanded round-trips an empty repository list")
func authoringPredecessorNotLandedRoundTripsEmptyRepositories() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .authoringPredecessorNotLanded(featureIssueID: "FEAT-0", repositories: []),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    guard case .authoringPredecessorNotLanded(_, let readRepositories) = records[0].event else {
        Issue.record("Event is not authoringPredecessorNotLanded")
        return
    }
    #expect(readRepositories.isEmpty)
}
