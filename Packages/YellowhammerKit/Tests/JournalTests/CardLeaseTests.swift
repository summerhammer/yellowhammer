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

/// Helper to insert a fixture feature → cycle → card chain and return the card id.
private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String,
    authoredOrder: Int = 1
) throws -> Int64 {
    try journal.write { db in
        // Insert feature
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID: Int64 = db.lastInsertedRowID

        // Insert cycle
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID: Int64 = db.lastInsertedRowID

        // Insert card
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

@Test("A fresh Card has no lease, and the first run claims it")
func cardFirstClaimSucceeds() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()

    #expect(try journal.currentCardLease(cardID: cardID) == nil)

    let claim = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    let expected = CardLease(
        cardID: cardID, runID: run,
        claimedAt: epoch, heartbeatAt: epoch, expiresAt: epoch.addingTimeInterval(600)
    )
    #expect(claim == .claimed(expected))
    #expect(try journal.currentCardLease(cardID: cardID) == expected)
}

@Test("Claiming a card that does not exist throws cardUnknown")
func claimNonexistentCardThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let fakeCardID: Int64 = 999

    #expect(throws: JournalError.cardUnknown(cardID: fakeCardID)) {
        try journal.claimCardLease(cardID: fakeCardID, runID: RunID(), now: epoch)
    }
}

@Test("A second run of the same Project is told who holds the Card and claims nothing")
func cardOverlappingRunIsHeldOff() throws {
    let fixture = try JournalFixture()
    let first = try fixture.open()
    let second = try fixture.open()
    let cardID = try insertFixtureCard(first, issueID: "CARD-1", repository: "main")
    let firstRun = RunID()
    let secondRun = RunID()

    let claim = try first.claimCardLease(cardID: cardID, runID: firstRun, now: epoch)
    guard case .claimed(let holder) = claim else {
        Issue.record("The first run did not claim the Card")
        return
    }

    let lastMoment = epoch.addingTimeInterval(599)
    let overlap = try second.claimCardLease(cardID: cardID, runID: secondRun, now: lastMoment)

    #expect(overlap == .held(holder))
    #expect(try second.currentCardLease(cardID: cardID) == holder)
    #expect(try second.releaseCardLease(cardID: cardID, runID: secondRun) == false)
    #expect(try second.currentCardLease(cardID: cardID) == holder)
}

@Test("A Card lease with no heartbeat for the TTL is dead and the next run takes it over")
func cardExpiredLeaseIsReclaimed() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let dead = RunID()
    let next = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: dead, now: epoch)

    let atExpiry = epoch.addingTimeInterval(600)
    let claim = try journal.claimCardLease(cardID: cardID, runID: next, now: atExpiry)

    guard case .claimed(let lease) = claim else {
        Issue.record("The expired lease was not reclaimed")
        return
    }
    #expect(lease.runID == next)
    #expect(lease.claimedAt == atExpiry)
    #expect(lease.expiresAt == atExpiry.addingTimeInterval(600))
}

@Test("A reclaim records exactly one CardLeaseReclaimed event with the card id, dead run id, and expiry")
func reclaimRecordsEvent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let dead = RunID()
    let next = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: dead, now: epoch)

    let atExpiry = epoch.addingTimeInterval(600)
    _ = try journal.claimCardLease(cardID: cardID, runID: next, now: atExpiry)

    let events = try journal.events(ofType: .cardLeaseReclaimed)
    #expect(events.count == 1)
    guard case .cardLeaseReclaimed(let recordedCardID, let recordedRunID, let recordedExpiry) = events[0].event else {
        Issue.record("Event is not cardLeaseReclaimed")
        return
    }
    #expect(recordedCardID == cardID)
    #expect(recordedRunID == dead)
    #expect(recordedExpiry == epoch.addingTimeInterval(600))
    #expect(events[0].runID == next)
}

@Test("A Card heartbeat pushes the expiry out by the TTL and keeps the claim time")
func cardHeartbeatExtendsExpiry() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    let beat = epoch.addingTimeInterval(60)
    let refreshed = try journal.heartbeatCardLease(cardID: cardID, runID: run, now: beat)

    #expect(refreshed.claimedAt == epoch)
    #expect(refreshed.heartbeatAt == beat)
    #expect(refreshed.expiresAt == beat.addingTimeInterval(600))
    #expect(try journal.currentCardLease(cardID: cardID) == refreshed)

    // Still held at the original expiry, because it was heartbeated.
    let other = try journal.claimCardLease(cardID: cardID, runID: RunID(), now: epoch.addingTimeInterval(601))
    #expect(other == .held(refreshed))
}

@Test("A run that slept past its TTL and lost the Card learns so on its next Card heartbeat")
func cardHeartbeatAfterLossThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let sleeper = RunID()
    let taker = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: sleeper, now: epoch)
    guard case .claimed(let takerLease) = try journal.claimCardLease(
        cardID: cardID, runID: taker, now: epoch.addingTimeInterval(700)
    ) else {
        Issue.record("The expired lease was not reclaimed")
        return
    }

    #expect(throws: JournalError.cardLeaseLost(cardID: cardID, runID: sleeper, holder: takerLease)) {
        try journal.heartbeatCardLease(cardID: cardID, runID: sleeper, now: epoch.addingTimeInterval(701))
    }
    // The sleeper's heartbeat changed nothing.
    #expect(try journal.currentCardLease(cardID: cardID) == takerLease)
}

@Test("A run whose Card lease expired with nobody taking it must claim again, not heartbeat")
func cardHeartbeatOnOwnExpiredLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    guard case .claimed(let lease) = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch) else {
        Issue.record("The first run did not claim the Card")
        return
    }

    #expect(throws: JournalError.cardLeaseLost(cardID: cardID, runID: run, holder: lease)) {
        try journal.heartbeatCardLease(cardID: cardID, runID: run, now: epoch.addingTimeInterval(600))
    }
}

@Test("Releasing frees the Card for the next run; releasing twice is a no-op")
func releaseFreesTheCard() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    #expect(try journal.releaseCardLease(cardID: cardID, runID: run) == true)
    #expect(try journal.currentCardLease(cardID: cardID) == nil)
    #expect(try journal.releaseCardLease(cardID: cardID, runID: run) == false)
    #expect(throws: JournalError.cardLeaseLost(cardID: cardID, runID: run, holder: nil)) {
        try journal.heartbeatCardLease(cardID: cardID, runID: run, now: epoch.addingTimeInterval(1))
    }

    let next = try journal.claimCardLease(cardID: cardID, runID: RunID(), now: epoch.addingTimeInterval(1))
    guard case .claimed = next else {
        Issue.record("The released Card was not claimable")
        return
    }
}

@Test("The run that holds the Card may claim it again and keeps its original claim time")
func cardReclaimByHolderIsIdempotent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    let again = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch.addingTimeInterval(30))

    let expected = CardLease(
        cardID: cardID, runID: run,
        claimedAt: epoch, heartbeatAt: epoch.addingTimeInterval(30), expiresAt: epoch.addingTimeInterval(630)
    )
    #expect(again == .claimed(expected))
}

@Test("The Card lease TTL and heartbeat are policy, merely true today")
func cardPolicyIsConfigurable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    let policy = LeasePolicy(heartbeatInterval: 1, timeToLive: 5)

    guard case .claimed(let lease) = try journal.claimCardLease(
        cardID: cardID, runID: run, policy: policy, now: epoch
    ) else {
        Issue.record("The first run did not claim the Card")
        return
    }
    #expect(lease.expiresAt == epoch.addingTimeInterval(5))
    let refreshed = try journal.heartbeatCardLease(
        cardID: cardID, runID: run, policy: policy, now: epoch.addingTimeInterval(3)
    )
    #expect(refreshed.expiresAt == epoch.addingTimeInterval(8))
}

@Test("Two Cards leased by one run are independent")
func multipleCardsAreIndependent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let card1ID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let card2ID = try insertFixtureCard(journal, issueID: "CARD-2", repository: "main", authoredOrder: 2)
    let run = RunID()

    _ = try journal.claimCardLease(cardID: card1ID, runID: run, now: epoch)
    _ = try journal.claimCardLease(cardID: card2ID, runID: run, now: epoch)

    // Release one
    #expect(try journal.releaseCardLease(cardID: card1ID, runID: run) == true)
    #expect(try journal.currentCardLease(cardID: card1ID) == nil)
    #expect(try journal.currentCardLease(cardID: card2ID) != nil)

    // cardLeases lists both then one
    let leases = try journal.cardLeases(heldBy: run)
    #expect(leases.count == 1)
    #expect(leases[0].cardID == card2ID)
}

@Test("A lease on one Card does not block a claim on a different Card by another run")
func differentCardsAreIndependent() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let card1ID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let card2ID = try insertFixtureCard(journal, issueID: "CARD-2", repository: "main", authoredOrder: 2)
    let run1 = RunID()
    let run2 = RunID()

    _ = try journal.claimCardLease(cardID: card1ID, runID: run1, now: epoch)
    let claim = try journal.claimCardLease(cardID: card2ID, runID: run2, now: epoch)

    guard case .claimed = claim else {
        Issue.record("Run 2 could not claim a different Card")
        return
    }
}

@Test("Revalidate succeeds while held")
func revalidateSucceedsWhileHeld() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    let revalidated = try journal.revalidateCardLease(cardID: cardID, runID: run, now: epoch.addingTimeInterval(60))
    #expect(revalidated.cardID == cardID)
    #expect(revalidated.runID == run)
}

@Test("Revalidate throws once expired")
func revalidateThrowsWhenExpired() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let run = RunID()
    _ = try journal.claimCardLease(cardID: cardID, runID: run, now: epoch)

    // After expiry, holder is the expired lease (same run), not nil
    do {
        try journal.revalidateCardLease(cardID: cardID, runID: run, now: epoch.addingTimeInterval(601))
        Issue.record("Should have thrown cardLeaseLost")
    } catch let error as JournalError {
        guard case .cardLeaseLost(let checkCardID, let checkRunID, let holder) = error else {
            Issue.record("Wrong error type")
            return
        }
        #expect(checkCardID == cardID)
        #expect(checkRunID == run)
        // Holder will be the expired lease
        #expect(holder != nil)
    }
}

@Test("Revalidate throws for a non-holder")
func revalidateThrowsForNonHolder() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let holder = RunID()
    let other = RunID()
    let lease = try journal.claimCardLease(cardID: cardID, runID: holder, now: epoch)

    guard case .claimed(let heldLease) = lease else {
        Issue.record("Holder did not claim")
        return
    }

    #expect(throws: JournalError.cardLeaseLost(cardID: cardID, runID: other, holder: heldLease)) {
        try journal.revalidateCardLease(cardID: cardID, runID: other, now: epoch.addingTimeInterval(60))
    }
}
