import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Split out of EventEncodingTests.swift to keep that file under the length limit. Round-trips the
// Refusal lifecycle's own events (roadmap P9.7): opened, repeated, expired and count-reset.

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

@Test("refusalOpened event round-trips")
func refusalOpenedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .refusalOpened(feature: "FEAT-1", consecutiveRefusals: 1), act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .refusalOpened(let feature, let consecutiveRefusals, _, _) = records[0].event else {
        Issue.record("Event is not refusalOpened")
        return
    }
    #expect(feature == "FEAT-1")
    #expect(consecutiveRefusals == 1)
}

@Test("refusalRepeated event round-trips")
func refusalRepeatedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .refusalRepeated(feature: "FEAT-1", consecutiveRefusals: 2), act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .refusalRepeated(let feature, let consecutiveRefusals, _, _) = records[0].event else {
        Issue.record("Event is not refusalRepeated")
        return
    }
    #expect(feature == "FEAT-1")
    #expect(consecutiveRefusals == 2)
}

@Test("refusalExpired event round-trips with an issue id")
func refusalExpiredRoundTripsWithIssueID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .refusalExpired(feature: "FEAT-1", issueID: "FEAT-1", unansweredNights: 2, bound: 1),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .refusalExpired(let feature, let issueID, let unansweredNights, let bound) = records[0].event else {
        Issue.record("Event is not refusalExpired")
        return
    }
    #expect(feature == "FEAT-1")
    #expect(issueID == "FEAT-1")
    #expect(unansweredNights == 2)
    #expect(bound == 1)
}

@Test("refusalExpired event round-trips with a nil issue id")
func refusalExpiredRoundTripsWithNilIssueID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .refusalExpired(feature: "FEAT-1", issueID: nil, unansweredNights: 2, bound: 1),
        act: .author, runID: run, now: epoch
    )
    let records = try journal.events()

    guard case .refusalExpired(_, let issueID, _, _) = records[0].event else {
        Issue.record("Event is not refusalExpired")
        return
    }
    #expect(issueID == nil)
}

@Test("refusalCountReset event round-trips")
func refusalCountResetRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.refusalCountReset(feature: "FEAT-1"), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .refusalCountReset(let feature) = records[0].event else {
        Issue.record("Event is not refusalCountReset")
        return
    }
    #expect(feature == "FEAT-1")
}
