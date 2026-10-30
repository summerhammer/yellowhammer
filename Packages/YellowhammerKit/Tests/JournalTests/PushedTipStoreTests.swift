import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Pushed Tip (feature-authoring/select-the-next-feature, `#pushed-tip`; OQ164, OQ191 item 2): the commit
// the land Act pushed for a Cycle in a repository, recorded once per (Cycle, repository) and pinned in the main
// clone at `refs/yellowhammer/landed/<branch>`.

private struct PushedTipJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-pushed-tip-\(UUID().uuidString)", directoryHint: .isDirectory)
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

/// A Feature and its Cycle.
private func insertFeature(_ journal: JournalStore) throws -> (featureID: Int64, cycleID: Int64) {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["FEAT-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        return (featureID, db.lastInsertedRowID)
    }
}

private func claimLease(_ journal: JournalStore, runID: RunID) throws {
    guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

@Suite("Pushed Tip store")
struct PushedTipStoreTests {
    @Test("a recorded Pushed Tip reads back, per Cycle and per Feature; an unrecorded pair reads nil")
    func roundTrip() throws {
        let fixture = try PushedTipJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let (featureID, cycleID) = try insertFeature(journal)
        try journal.recordFeatureBranch(featureID: featureID, repository: "backend", branch: "yh-p-f")
        try journal.recordFeatureBranch(featureID: featureID, repository: "mobile", branch: "yh-p-f")

        #expect(try journal.pushedTip(cycleID: cycleID, repository: "backend") == nil)
        #expect(try journal.pushedTips(featureID: featureID).isEmpty)

        let recorded = try journal.recordPushedTip(
            cycleID: cycleID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        #expect(recorded)
        #expect(try journal.pushedTip(cycleID: cycleID, repository: "backend") == "aaa111")
        #expect(try journal.pushedTip(cycleID: cycleID, repository: "mobile") == nil)

        try journal.recordPushedTip(cycleID: cycleID, repository: "mobile", commit: "bbb222", runID: runID, now: epoch)
        #expect(try journal.pushedTips(featureID: featureID) == ["backend": "aaa111", "mobile": "bbb222"])
        // The Feature Branch the pair already had is untouched.
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == "yh-p-f")
    }

    // feature-authoring/stories/select-the-next-feature.md#pushed-tip
    @Test("a second write for the same Cycle and repository does not replace the first")
    func secondWriteDoesNotReplaceTheFirst() throws {
        let fixture = try PushedTipJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let (featureID, cycleID) = try insertFeature(journal)

        let first = try journal.recordPushedTip(
            cycleID: cycleID, repository: "backend", commit: "aaa111", runID: runID, now: epoch
        )
        let second = try journal.recordPushedTip(
            cycleID: cycleID, repository: "backend", commit: "ccc333", runID: runID, now: epoch
        )
        #expect(first)
        #expect(!second)
        #expect(try journal.pushedTip(cycleID: cycleID, repository: "backend") == "aaa111")
        #expect(try journal.pushedTips(featureID: featureID) == ["backend": "aaa111"])
    }

    @Test("a pushed repository with no row yet gets one, and no Feature Branch is invented")
    func createsTheRowOfAPushedRepository() throws {
        let fixture = try PushedTipJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let (featureID, cycleID) = try insertFeature(journal)

        try journal.recordPushedTip(cycleID: cycleID, repository: "backend", commit: "aaa111", runID: runID, now: epoch)
        #expect(try journal.pushedTip(cycleID: cycleID, repository: "backend") == "aaa111")
        #expect(try journal.touchedRepositories(featureID: featureID) == ["backend"])
        #expect(try journal.featureBranch(featureID: featureID, repository: "backend") == nil)
    }

    @Test("an unknown Cycle and a lost Act lease both refuse, and write nothing")
    func refusals() throws {
        let fixture = try PushedTipJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLease(journal, runID: runID)
        let (featureID, cycleID) = try insertFeature(journal)

        #expect(throws: JournalError.cycleUnknown(cycleID: cycleID + 1)) {
            try journal.recordPushedTip(
                cycleID: cycleID + 1, repository: "backend", commit: "aaa111", runID: runID, now: epoch
            )
        }
        #expect(throws: (any Error).self) {
            try journal.recordPushedTip(
                cycleID: cycleID, repository: "backend", commit: "aaa111", runID: RunID(), now: epoch
            )
        }
        #expect(try journal.pushedTips(featureID: featureID).isEmpty)
    }

    @Test("landedPinFailed round-trips through the event log")
    func eventRoundTrips() throws {
        let fixture = try PushedTipJournalFixture()
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
