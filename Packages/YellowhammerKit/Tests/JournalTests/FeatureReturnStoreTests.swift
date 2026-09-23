import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.6 (spec: verification/return-a-feature-with-unmet-clauses): `recordFeatureReturned` sets
// `feature.state = 'returned'` once, revalidating the Act Lease first, the same way
// `markCycleLanded` does.

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

private func makeFeature(_ journal: JournalStore, issueID: String = "FEAT-1") throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func featureState(_ journal: JournalStore, featureID: Int64) throws -> String {
    try journal.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM feature WHERE id = ?", arguments: [featureID])!
    }
}

@Suite("Record a Feature returned (P10.6)")
struct FeatureReturnStoreTests {
    @Test("A first call sets state to 'returned' and returns true")
    func recordsOnFirstCall() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }

        let first = try journal.recordFeatureReturned(featureID: featureID, runID: runID, now: epoch)

        #expect(first)
        #expect(try featureState(journal, featureID: featureID) == "returned")
    }

    @Test("A retry (already returned) is a no-op and returns false")
    func secondCallIsANoOp() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        _ = try journal.recordFeatureReturned(featureID: featureID, runID: runID, now: epoch)

        let second = try journal.recordFeatureReturned(featureID: featureID, runID: runID, now: epoch)

        #expect(!second)
        #expect(try featureState(journal, featureID: featureID) == "returned")
    }

    @Test("An unknown Feature id throws")
    func unknownFeatureThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }

        #expect(throws: JournalError.featureUnknown(featureID: 999)) {
            try journal.recordFeatureReturned(featureID: 999, runID: runID, now: epoch)
        }
    }

    @Test("A run that does not hold the Act Lease cannot record the return")
    func requiresTheActLease() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)

        #expect(throws: (any Error).self) {
            try journal.recordFeatureReturned(featureID: featureID, runID: RunID(), now: epoch)
        }
    }
}
