import Domain
import Foundation
import Testing

@testable import Journal

// The Readiness Check's own events (roadmap P8.2) round-trip here, split out of
// EventEncodingTests.swift to keep that file under the length limit.

private struct ReadinessEventFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-readiness-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let readinessEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test("readinessCheckPassed event round-trips")
func readinessCheckPassedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .readinessCheckPassed(cardID: 1, issueID: "issue-1"), act: .build, runID: run, now: readinessEpoch
    )
    let records = try journal.events(ofType: .readinessCheckPassed)

    #expect(records.count == 1)
    #expect(records[0].event == .readinessCheckPassed(cardID: 1, issueID: "issue-1"))
}

@Test("readinessCheckFailed event round-trips, empty and non-empty failures")
func readinessCheckFailedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .readinessCheckFailed(cardID: 1, issueID: "issue-1", failures: ["no brief", "no DoD"]),
        act: .build, runID: run, now: readinessEpoch
    )
    try journal.append(
        .readinessCheckFailed(cardID: 2, issueID: "issue-2", failures: []),
        act: .build, runID: run, now: readinessEpoch
    )
    let records = try journal.events(ofType: .readinessCheckFailed)

    #expect(records.count == 2)
    #expect(records[0].event == .readinessCheckFailed(cardID: 1, issueID: "issue-1", failures: ["no brief", "no DoD"]))
    #expect(records[1].event == .readinessCheckFailed(cardID: 2, issueID: "issue-2", failures: []))
}

@Test("cardDiverged event round-trips")
func cardDivergedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .cardDiverged(cardID: 1, issueID: "issue-1", repository: "backend", changedPaths: ["a.swift", "b.swift"]),
        act: .build, runID: run, now: readinessEpoch
    )
    let records = try journal.events(ofType: .cardDiverged)

    #expect(records.count == 1)
    #expect(
        records[0].event ==
            .cardDiverged(cardID: 1, issueID: "issue-1", repository: "backend", changedPaths: ["a.swift", "b.swift"])
    )
}

@Test("transcriptionStampVoided event round-trips")
func transcriptionStampVoidedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .transcriptionStampVoided(cardID: 1, issueID: "issue-1", repository: "backend"),
        act: .build, runID: run, now: readinessEpoch
    )
    let records = try journal.events(ofType: .transcriptionStampVoided)

    #expect(records.count == 1)
    #expect(records[0].event == .transcriptionStampVoided(cardID: 1, issueID: "issue-1", repository: "backend"))
}

@Test("clauseMinted event round-trips")
func clauseMintedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.clauseMinted(issueID: "issue-1", cid: "c3"), act: .build, runID: run, now: readinessEpoch)
    let records = try journal.events(ofType: .clauseMinted)

    #expect(records.count == 1)
    #expect(records[0].event == .clauseMinted(issueID: "issue-1", cid: "c3"))
}

@Test("clauseInvalidated event round-trips")
func clauseInvalidatedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .clauseInvalidated(issueID: "issue-1", cid: "c1", cause: "text_edited"),
        act: .build, runID: run, now: readinessEpoch
    )
    let records = try journal.events(ofType: .clauseInvalidated)

    #expect(records.count == 1)
    #expect(records[0].event == .clauseInvalidated(issueID: "issue-1", cid: "c1", cause: "text_edited"))
}

@Test("clauseDeleted event round-trips")
func clauseDeletedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.clauseDeleted(issueID: "issue-1", cid: "c1"), act: .build, runID: run, now: readinessEpoch)
    let records = try journal.events(ofType: .clauseDeleted)

    #expect(records.count == 1)
    #expect(records[0].event == .clauseDeleted(issueID: "issue-1", cid: "c1"))
}

@Test("protectedPathRefused event round-trips")
func protectedPathRefusedRoundTrips() throws {
    let fixture = try ReadinessEventFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .protectedPathRefused(
            cardID: 1, issueID: "issue-1", repository: "backend",
            declaredPath: "Secrets/keys.env", protectedPath: "Secrets/"
        ),
        act: .build, runID: run, now: readinessEpoch
    )
    let records = try journal.events(ofType: .protectedPathRefused)

    #expect(records.count == 1)
    #expect(
        records[0].event ==
            .protectedPathRefused(
                cardID: 1, issueID: "issue-1", repository: "backend",
                declaredPath: "Secrets/keys.env", protectedPath: "Secrets/"
            )
    )
}
