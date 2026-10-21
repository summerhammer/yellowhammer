import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Observed Release gate's Journal state (feature-authoring/select-the-next-feature, `#release-gate`).

private struct ReleaseJournalFixture: ~Copyable {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        let projectID = try #require(ProjectID(rawValue: "fixture"))
        return try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

/// A Feature with an archived Cycle (unless `inFlight`) touching `repositories`; `abandoned` sets `abandoned_at`.
@discardableResult
private func insertFeature(
    _ journal: JournalStore, issueID: String, repositories: [String], abandoned: Bool = false,
    inFlight: Bool = false
) throws -> Int64 {
    let stamp = JournalStore.timestamp(Date(timeIntervalSince1970: 1_800_000_000))
    return try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, abandoned_at, created_at) VALUES (?, ?, ?, ?)",
            arguments: [issueID, "selected", abandoned ? stamp : nil, stamp]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at) VALUES (?, ?, ?)",
            arguments: [featureID, stamp, inFlight ? nil : stamp]
        )
        for repository in repositories {
            try db.execute(
                sql: "INSERT INTO feature_repository (feature_id, repository) VALUES (?, ?)",
                arguments: [featureID, repository]
            )
        }
        return featureID
    }
}

@Suite("Observed Release records")
struct FeatureReleaseTests {
    @Test("The first observed release of a Feature in a producer Repo wins and reads back")
    func firstObservationWins() throws {
        let fixture = ReleaseJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertFeature(journal, issueID: "FEAT-1", repositories: ["contracts"])

        #expect(try journal.releases(featureID: featureID).isEmpty)
        #expect(try journal.recordRelease(
            featureID: featureID, repository: "contracts", tagName: "v1.0.0", tagCommit: "aaa"
        ))
        #expect(try !journal.recordRelease(
            featureID: featureID, repository: "contracts", tagName: "v2.0.0", tagCommit: "bbb"
        ))

        #expect(try journal.releases(featureID: featureID) == [
            "contracts": ObservedRelease(tagName: "v1.0.0", tagCommit: "aaa")
        ])
    }

    @Test("latestFeaturePushed returns the most recent archived, non-abandoned Feature that pushed there")
    func latestFeaturePushedSkipsWhatDoesNotQualify() throws {
        let fixture = ReleaseJournalFixture()
        let journal = try fixture.open()
        #expect(try journal.latestFeaturePushed(in: "contracts") == nil)

        try insertFeature(journal, issueID: "FEAT-OLD", repositories: ["contracts"])
        let wanted = try insertFeature(journal, issueID: "FEAT-WANTED", repositories: ["contracts", "backend"])
        try insertFeature(journal, issueID: "FEAT-ABANDONED", repositories: ["contracts"], abandoned: true)
        try insertFeature(journal, issueID: "FEAT-OTHER", repositories: ["backend"])
        try insertFeature(journal, issueID: "FEAT-INFLIGHT", repositories: ["contracts"], inFlight: true)

        let latest = try #require(try journal.latestFeaturePushed(in: "contracts"))
        #expect(latest.id == wanted)
        #expect(latest.issueID == "FEAT-WANTED")
        #expect(try journal.latestFeaturePushed(in: "mobile") == nil)
    }

    @Test("A Feature with a No-Pushed-Branch Outcome in the Repo did not push there")
    func noPushedBranchIsNotAPush() throws {
        let fixture = ReleaseJournalFixture()
        let journal = try fixture.open()
        let older = try insertFeature(journal, issueID: "FEAT-PUSHED", repositories: ["contracts"])
        let newer = try insertFeature(journal, issueID: "FEAT-NOPUSH", repositories: ["contracts"])
        try journal.append(
            .noPushedBranchOutcome(cycleID: 1, featureIssueID: "FEAT-NOPUSH", repository: "contracts"),
            act: .land, runID: RunID()
        )
        #expect(older < newer)
        #expect(try journal.latestFeaturePushed(in: "contracts")?.id == older)
    }

    @Test("observedReleaseRecorded and authoringReleaseGateHeld round-trip")
    func eventsRoundTrip() throws {
        let fixture = ReleaseJournalFixture()
        let journal = try fixture.open()
        let run = RunID()
        let recorded = JournalEvent.observedReleaseRecorded(
            featureIssueID: "FEAT-1", repository: "contracts", tagName: "v1.2.3", tagCommit: "abc123"
        )
        let held = JournalEvent.authoringReleaseGateHeld(
            featureName: "Add login", consumer: "backend", producer: "contracts", producerFeatureIssueID: "FEAT-1",
                hold: .awaitingRelease
        )
        try journal.append(recorded, act: .author, runID: run)
        try journal.append(held, act: .author, runID: run)

        let records = try journal.events()
        #expect(records.map(\.type) == [.observedReleaseRecorded, .authoringReleaseGateHeld])
        #expect(records.map(\.event) == [recorded, held])
        #expect(records[0].type.rawValue == "ObservedReleaseRecorded")
        #expect(records[1].type.rawValue == "AuthoringReleaseGateHeld")
    }
}
