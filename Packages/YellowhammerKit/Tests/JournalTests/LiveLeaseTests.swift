import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

/// A throwaway configuration directory holding one Project's Journal. Removed on deinit.
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

@Test("A fresh Journal holds no live Lease")
func emptyJournalHoldsNoLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    #expect(try journal.holdsLiveLease(now: epoch) == false)
}

@Test("A live Card lease counts as a live Lease")
func liveCardLeaseIsLive() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    _ = try journal.claimCardLease(cardID: cardID, runID: RunID(), now: epoch)

    #expect(try journal.holdsLiveLease(now: epoch.addingTimeInterval(1)) == true)
}

@Test("An expired Card lease does not count as a live Lease")
func expiredCardLeaseIsNotLive() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    _ = try journal.claimCardLease(cardID: cardID, runID: RunID(), now: epoch)

    #expect(try journal.holdsLiveLease(now: epoch.addingTimeInterval(600)) == false)
}

@Test("A live Act lease counts as a live Lease")
func liveActLeaseIsLive() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)

    #expect(try journal.holdsLiveLease(now: epoch.addingTimeInterval(1)) == true)
}

@Test("An expired Act lease does not count as a live Lease")
func expiredActLeaseIsNotLive() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)

    #expect(try journal.holdsLiveLease(now: epoch.addingTimeInterval(600)) == false)
}

@Test("A live Lease is visible through a read-only connection")
func liveLeaseVisibleReadOnly() throws {
    let fixture = try JournalFixture()
    let writer = try fixture.open()
    _ = try writer.claimActLease(act: .build, runID: RunID(), mode: .real, now: epoch)

    let reader = try JournalStore.openReadOnly(
        at: JournalStore.defaultFileURL(configurationDirectory: fixture.directory, id: fixture.projectID),
        projectID: fixture.projectID
    )
    #expect(try reader.holdsLiveLease(now: epoch.addingTimeInterval(1)) == true)
}
