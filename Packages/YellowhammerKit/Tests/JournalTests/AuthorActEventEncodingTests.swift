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

@Test("predecessorAncestryObserved event round-trips")
func predecessorAncestryObservedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .predecessorAncestryObserved(
            featureIssueID: "FEAT-0",
            mergedRepositories: ["backend"],
            unmergedRepositories: ["mobile", "web"]
        ),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard
        case .predecessorAncestryObserved(let featureIssueID, let merged, let unmerged) = records[0].event
    else {
        Issue.record("Event is not predecessorAncestryObserved")
        return
    }
    #expect(featureIssueID == "FEAT-0")
    #expect(merged == ["backend"])
    #expect(unmerged == ["mobile", "web"])
}

@Test("predecessorAncestryObserved round-trips empty merged and unmerged lists")
func predecessorAncestryObservedRoundTripsEmptyLists() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .predecessorAncestryObserved(featureIssueID: "FEAT-0", mergedRepositories: [], unmergedRepositories: []),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    guard
        case .predecessorAncestryObserved(_, let merged, let unmerged) = records[0].event
    else {
        Issue.record("Event is not predecessorAncestryObserved")
        return
    }
    #expect(merged.isEmpty)
    #expect(unmerged.isEmpty)
}

@Test("mainlineConflictDetected event round-trips")
func mainlineConflictDetectedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let paths = ["Sources/A.swift", "Sources/B.swift"]

    try journal.append(
        .mainlineConflictDetected(featureIssueID: "FEAT-0", repository: "backend", paths: paths),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard
        case .mainlineConflictDetected(let featureIssueID, let repository, let readPaths) = records[0].event
    else {
        Issue.record("Event is not mainlineConflictDetected")
        return
    }
    #expect(featureIssueID == "FEAT-0")
    #expect(repository == "backend")
    #expect(readPaths == paths)
}

@Test("mainlineConflictDetected round-trips an empty path list")
func mainlineConflictDetectedRoundTripsEmptyPaths() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .mainlineConflictDetected(featureIssueID: "FEAT-0", repository: "backend", paths: []),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    guard
        case .mainlineConflictDetected(_, _, let readPaths) = records[0].event
    else {
        Issue.record("Event is not mainlineConflictDetected")
        return
    }
    #expect(readPaths.isEmpty)
}

@Test("featureSelected event round-trips with every optional present and non-empty arrays")
func featureSelectedRoundTripsFullyPopulated() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let payload = FeatureSelectedPayload(
        name: "FEAT-1", reasoning: "Splits the seam cleanly.",
        precededBy: "FEAT-0", followedBy: "FEAT-2", seam: "the endpoint contract",
        repositories: ["backend", "mobile"],
        adoptedCardIssueIDs: ["BACK-1"], unadoptedCardIssueIDs: ["BACK-2"]
    )

    try journal.append(.featureSelected(payload), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .featureSelected(let read) = records[0].event else {
        Issue.record("Event is not featureSelected")
        return
    }
    #expect(read == payload)
}

@Test("featureSelected event round-trips with every optional nil and every array empty")
func featureSelectedRoundTripsMinimal() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let payload = FeatureSelectedPayload(
        name: "FEAT-1", reasoning: "No predecessor, no successor.",
        precededBy: nil, followedBy: nil, seam: nil,
        repositories: ["backend"], adoptedCardIssueIDs: [], unadoptedCardIssueIDs: []
    )

    try journal.append(.featureSelected(payload), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    guard case .featureSelected(let read) = records[0].event else {
        Issue.record("Event is not featureSelected")
        return
    }
    #expect(read == payload)
    #expect(read.precededBy == nil)
    #expect(read.followedBy == nil)
    #expect(read.seam == nil)
    #expect(read.adoptedCardIssueIDs.isEmpty)
    #expect(read.unadoptedCardIssueIDs.isEmpty)
}

@Test("featureAuthoringHalted event round-trips with a detail")
func featureAuthoringHaltedRoundTripsWithDetail() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .featureAuthoringHalted(
            name: "FEAT-1", reasonKind: "no-backward-compatible-seam", detail: "the shared contract"
        ),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .featureAuthoringHalted(let name, let reasonKind, let detail) = records[0].event else {
        Issue.record("Event is not featureAuthoringHalted")
        return
    }
    #expect(name == "FEAT-1")
    #expect(reasonKind == "no-backward-compatible-seam")
    #expect(detail == "the shared contract")
}

@Test("featureAuthoringHalted event round-trips with a nil detail")
func featureAuthoringHaltedRoundTripsWithNilDetail() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .featureAuthoringHalted(name: "FEAT-1", reasonKind: "repositories-undetermined", detail: nil),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    guard case .featureAuthoringHalted(_, _, let detail) = records[0].event else {
        Issue.record("Event is not featureAuthoringHalted")
        return
    }
    #expect(detail == nil)
}
