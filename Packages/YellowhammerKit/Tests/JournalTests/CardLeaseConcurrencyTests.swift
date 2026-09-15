import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

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
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, "card", authoredOrder, "pending",
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

@Test("Two connections racing for the Card lease on the same Card: exactly one claims it")
func cardRacingClaimsSerialise() async throws {
    let fixture = try JournalFixture()
    let fixtureJournal = try fixture.open()
    let cardID = try insertFixtureCard(fixtureJournal, issueID: "CARD-1", repository: "main")
    let stores = try (0..<8).map { _ in try fixture.open() }

    let claims = try await withThrowingTaskGroup(of: CardLeaseClaim.self) { group in
        for store in stores {
            group.addTask {
                try store.claimCardLease(cardID: cardID, runID: RunID())
            }
        }
        return try await group.reduce(into: [CardLeaseClaim]()) { $0.append($1) }
    }

    let claimed = claims.compactMap { claim -> CardLease? in
        if case .claimed(let lease) = claim { return lease }
        return nil
    }
    #expect(claimed.count == 1)
    let holders = Set(claims.map { claim -> RunID in
        switch claim {
        case .claimed(let lease), .held(let lease): lease.runID
        case .reclaimed(let lease, expired: _): lease.runID
        }
    })
    #expect(holders == Set(claimed.map(\.runID)))
}

@Test("The Database-level static revalidate works inside a write transaction and writes nothing")
func staticRevalidateWritesNothing() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    let original = try journal.currentCardLease(cardID: cardID)

    try journal.write { db in
        let ts = epoch.addingTimeInterval(60)
        let revalidated = try JournalStore.revalidateCardLease(db, cardID: cardID,
                                                                 runID: run, now: ts)
        #expect(revalidated == original)
    }

    #expect(try journal.currentCardLease(cardID: cardID) == original)
}

@Test("cardLeases(heldBy:) lists two then one after a release")
func cardLeasesListsMultiple() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let card1ID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let card2ID = try insertFixtureCard(journal, issueID: "CARD-2", repository: "main", authoredOrder: 2)
    let run = RunID()

    _ = try journal.claimCardLease(cardID: card1ID, runID: run, now: epoch)
    _ = try journal.claimCardLease(cardID: card2ID, runID: run, now: epoch)

    var leases = try journal.cardLeases(heldBy: run)
    #expect(leases.count == 2)

    _ = try journal.releaseCardLease(cardID: card1ID, runID: run)

    leases = try journal.cardLeases(heldBy: run)
    #expect(leases.count == 1)
    #expect(leases[0].cardID == card2ID)
}

@Test("Heartbeat after release throws cardLeaseLost with holder nil")
func heartbeatAfterReleaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()

    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)
    _ = try journal.releaseCardLease(cardID: cardID, runID: run)

    do {
        _ = try journal.heartbeatCardLease(cardID: cardID, runID: run, now: epoch.addingTimeInterval(1))
        Issue.record("Should have thrown cardLeaseLost")
    } catch let error as JournalError {
        guard case .cardLeaseLost(let checkCardID, let checkRunID, let holder) = error else {
            Issue.record("Wrong error type")
            return
        }
        #expect(checkCardID == cardID)
        #expect(checkRunID == run)
        #expect(holder == nil)
    }
}
