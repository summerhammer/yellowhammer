import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The landed commit (feature-authoring/select-the-next-feature, OQ164): the commit the land Act last pushed
// for a Feature in a repository, recorded per (Feature, repository) and pinned in the main clone at
// `refs/yellowhammer/landed/<branch>`.

private struct LandedJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-landed-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func insertFeature(_ journal: JournalStore) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func claimLease(_ journal: JournalStore, runID: RunID) throws {
    guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

@Suite("Landed commit store")
struct LandedCommitStoreTests {
    @Test("a recorded landed commit reads back, singly and in a batch; an unrecorded pair reads nil")
    func roundTrip() throws {
        let fixture = try LandedJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        try journal.recordFeatureBranch(featureID: featureID, repository: "mobile", branch: "yh-p-f")

        #expect(try journal.landedCommit(featureID: featureID, repository: "backend") == nil)
        #expect(try journal.landedCommits(featureID: featureID).isEmpty)

        try journal.recordLandedCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        #expect(try journal.landedCommit(featureID: featureID, repository: "backend") == "aaa111")
        #expect(try journal.landedCommit(featureID: featureID, repository: "mobile") == nil)

        try journal.recordLandedCommit(
            featureID: featureID, repository: "mobile", commit: "bbb222", runID: runID, now: epoch
        )
        #expect(try journal.landedCommits(featureID: featureID) == ["backend": "aaa111", "mobile": "bbb222"])
        // The Feature Branch the pair already had is untouched.
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == "yh-p-f")
    }

    @Test("a later push of the same Feature overwrites the landed commit")
    func laterPushOverwrites() throws {
        let fixture = try LandedJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)

        try journal.recordLandedCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        try journal.recordLandedCommit(
            featureID: featureID, repository: "backend", commit: "ccc333", runID: runID, now: epoch
        )
        #expect(try journal.landedCommit(featureID: featureID, repository: "backend") == "ccc333")
    }

    @Test("a pushed repository with no row yet gets one, and no Feature Branch is invented")
    func createsTheRowOfAPushedRepository() throws {
        let fixture = try LandedJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)

        try journal.recordLandedCommit(
            featureID: featureID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        #expect(try journal.landedCommit(featureID: featureID, repository: "backend") == "aaa111")
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == nil)
    }

    @Test("an unknown Feature and a lost Act lease both refuse, and write nothing")
    func refusals() throws {
        let fixture = try LandedJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let featureID = try insertFeature(journal)

        #expect(throws: (any Error).self) {
            try journal.recordLandedCommit(
                featureID: featureID + 1, repository: "backend", commit: "aaa111", runID: runID, now: epoch
            )
        }
        #expect(throws: (any Error).self) {
            try journal.recordLandedCommit(
                featureID: featureID, repository: "backend", commit: "aaa111", runID: RunID(), now: epoch
            )
        }
        #expect(try journal.landedCommits(featureID: featureID).isEmpty)
    }

    @Test("landedPinFailed round-trips through the event log")
    func eventRoundTrips() throws {
        let fixture = try LandedJournalFixture()
        let journal = try fixture.open()
        let event = JournalEvent.landedPinFailed(
            featureIssueID: "FEAT-1", repository: "backend", branch: "prefix/yh-p-f", commit: "aaa111",
            operation: .unpin, reason: "cannot lock ref"
        )
        try journal.append(event)

        let records = try journal.events(ofType: .landedPinFailed)
        #expect(records.map(\.event) == [event])
        #expect(JournalEventType.landedPinFailed.rawValue == "LandedPinFailed")
    }
}
