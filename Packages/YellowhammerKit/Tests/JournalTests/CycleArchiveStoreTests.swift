import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// roadmap P10.7 (spec: verification/archive-the-cycle-on-a-verified-feature): `archiveCycle` sets
// `cycle.archived_at`, `feature.closed_by` and `feature.state = 'closed'` once, revalidating the Act
// Lease first, the same way `markCycleLanded` does. A Blocked Card's Journal row is never touched, so a
// later adoption reads its counters, round history and Block Reason unchanged.

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

private func makeCycle(_ journal: JournalStore, featureID: Int64) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

@discardableResult
private func makeCard(
    _ journal: JournalStore, cycleID: Int64, issueID: String, state: String, budgetEpoch: Int = 3,
    blockReason: String? = nil
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch,
                created_at
            )
            VALUES (?, ?, 'backend', 'card', 1, ?, ?, ?, ?)
            """,
            arguments: [cycleID, issueID, state, blockReason, budgetEpoch, JournalStore.timestamp(epoch)]
        )
        return db.lastInsertedRowID
    }
}

private func featureRow(_ journal: JournalStore, featureID: Int64) throws -> (state: String, closedBy: String?) {
    try journal.read { db in
        let row = try Row.fetchOne(
            db, sql: "SELECT state, closed_by FROM feature WHERE id = ?", arguments: [featureID]
        )!
        return (row["state"], row["closed_by"])
    }
}

private func cycleArchivedAt(_ journal: JournalStore, cycleID: Int64) throws -> String? {
    try journal.read { db in
        try String.fetchOne(db, sql: "SELECT archived_at FROM cycle WHERE id = ?", arguments: [cycleID])
    }
}

@Suite("Archive the Cycle on a verified Feature (P10.7)")
struct CycleArchiveStoreTests {
    @Test("A first call archives the Cycle, records closed_by and closes the Feature, and returns true")
    func archivesOnFirstCall() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }

        let first = try journal.archiveCycle(
            cycleID: cycleID, featureID: featureID, closedBy: .verification, runID: runID, now: epoch
        )

        #expect(first)
        #expect(try cycleArchivedAt(journal, cycleID: cycleID) != nil)
        let row = try featureRow(journal, featureID: featureID)
        #expect(row.state == "closed")
        #expect(row.closedBy == "verification")
    }

    @Test("A retry (already archived) is a no-op and returns false")
    func secondCallIsANoOp() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }
        _ = try journal.archiveCycle(
            cycleID: cycleID, featureID: featureID, closedBy: .verification, runID: runID, now: epoch
        )
        let archivedAtFirst = try cycleArchivedAt(journal, cycleID: cycleID)

        let second = try journal.archiveCycle(
            cycleID: cycleID, featureID: featureID, closedBy: .verification, runID: runID, now: epoch
        )

        #expect(!second)
        #expect(try cycleArchivedAt(journal, cycleID: cycleID) == archivedAtFirst)
    }

    @Test("An unknown Cycle id throws")
    func unknownCycleThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }

        #expect(throws: JournalError.cycleUnknown(cycleID: 999)) {
            try journal.archiveCycle(
                cycleID: 999, featureID: featureID, closedBy: .verification, runID: runID, now: epoch
            )
        }
    }

    @Test("A run that does not hold the Act Lease cannot archive the Cycle")
    func requiresTheActLease() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)

        #expect(throws: (any Error).self) {
            try journal.archiveCycle(
                cycleID: cycleID, featureID: featureID, closedBy: .verification, runID: RunID(), now: epoch
            )
        }
    }

    @Test("A Blocked Card of the archived Cycle is left for adoption with its counters intact")
    func blockedCardSurvivesForAdoption() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let cardID = try makeCard(
            journal, cycleID: cycleID, issueID: "BACK-2", state: "Blocked", budgetEpoch: 4,
            blockReason: "route_exhausted"
        )
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }

        #expect(try journal.inFlightCycleID() == cycleID)

        _ = try journal.archiveCycle(
            cycleID: cycleID, featureID: featureID, closedBy: .verification, runID: runID, now: epoch
        )

        #expect(try journal.inFlightCycleID() == nil)
        let candidates = try journal.blockedCardsLeftByClosedFeatures()
        let candidate = try #require(candidates.first { $0.id == cardID })
        #expect(candidate.budgetEpoch == 4)
        #expect(candidate.blockReason == "route_exhausted")
        #expect(candidate.state == .blocked)
    }

    @Test("The cycleArchived event encodes and decodes with its Feature Issue id, route and detached count")
    func cycleArchivedEventRoundTrips() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let featureID = try makeFeature(journal)
        let cycleID = try makeCycle(journal, featureID: featureID)
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: epoch) else {
            Issue.record("expected the lease to be claimed")
            return
        }

        try journal.append(
            .cycleArchived(cycleID: cycleID, featureIssueID: "FEAT-1", closedBy: .verification, detachedCards: 2),
            act: .land, runID: runID, now: epoch
        )

        let events = try journal.events(ofType: .cycleArchived)
        #expect(events.map(\.event) == [
            .cycleArchived(cycleID: cycleID, featureIssueID: "FEAT-1", closedBy: .verification, detachedCards: 2)
        ])
    }
}
