import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// Issue #96 (DeferredCardStateReplay): a caller that runs no Card must not take over a dead
// run's expired Card Lease and release it once its own write lands — `ExpiredLeaseSweep` (build Act
// start, P8.10) reads that lease row to classify the crashed Attempt Crashed-Unknown, and a takeover
// would erase that evidence before the sweep ever saw it. Split out of CardLeaseTests.swift to stay
// under its file-length limit.

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

private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String,
    authoredOrder: Int = 1
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID: Int64 = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", authoredOrder, CardState.todo.rawValue, 0,
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Test("reclaimingExpired: false reports .held for another run's expired lease, and takes nothing over")
func nonReclaimingClaimReportsHeldForExpiredLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let dead = RunID()
    let replayer = RunID()
    guard case .claimed(let deadLease) = try journal.claimCardLease(cardID: cardID, runID: dead, now: epoch) else {
        Issue.record("The first run did not claim the Card")
        return
    }

    let afterExpiry = epoch.addingTimeInterval(601)
    let claim = try journal.claimCardLease(
        cardID: cardID, runID: replayer, reclaimingExpired: false, now: afterExpiry
    )

    #expect(claim == .held(deadLease))
    // The row is untouched: still the dead run's original lease.
    #expect(try journal.currentCardLease(cardID: cardID) == deadLease)
    #expect(try journal.events(ofType: .cardLeaseReclaimed).isEmpty)
}

@Test("reclaimingExpired defaults to true: an expired lease is still reclaimed as before")
func reclaimingExpiredDefaultsToTrue() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let dead = RunID()
    let next = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: dead, now: epoch)

    let atExpiry = epoch.addingTimeInterval(600)
    let claim = try journal.claimCardLease(cardID: cardID, runID: next, now: atExpiry)

    guard case .claimed(let lease) = claim else {
        Issue.record("The default parameter should still reclaim an expired lease")
        return
    }
    #expect(lease.runID == next)
    #expect(try journal.events(ofType: .cardLeaseReclaimed).count == 1)
}
