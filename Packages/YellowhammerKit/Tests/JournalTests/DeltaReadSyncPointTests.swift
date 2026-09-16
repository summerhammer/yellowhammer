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
            .appending(component: "yh-delta-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
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

// MARK: - Sync Point Tests

@Test("Fresh Journal has no sync point")
func freshJournalHasNoSyncPoint() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let syncPoint = try journal.boardSyncPoint()
    #expect(syncPoint == nil)
}

@Test("recordBoardSync stores and returns a sync point")
func recordBoardSyncStoresPoint() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let lastSync = Date(timeIntervalSince1970: 1_789_000_000)
    let recorded = try journal.recordBoardSync(
        lastSync: lastSync, runID: runID, now: epoch
    )

    #expect(recorded.lastSync == lastSync)
    #expect(recorded.readAt == epoch)
    #expect(recorded.runID == runID)

    let fetched = try journal.boardSyncPoint()
    #expect(fetched == recorded)
}

@Test("Fractional timestamp in lastSync round-trips exactly")
func fractionalTimestampRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let lastSync = Date(timeIntervalSince1970: 1_789_000_000.25)
    let recorded = try journal.recordBoardSync(
        lastSync: lastSync, runID: runID, now: epoch
    )

    #expect(recorded.lastSync == lastSync)

    let fetched = try journal.boardSyncPoint()
    #expect(fetched?.lastSync == lastSync)
}

@Test("Second recordBoardSync replaces the first")
func secondSyncPointReplaces() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    let time1 = Date(timeIntervalSince1970: 1_789_000_000)
    _ = try journal.recordBoardSync(lastSync: time1, runID: runID, now: epoch)

    let time2 = Date(timeIntervalSince1970: 1_790_000_000)
    let recorded2 = try journal.recordBoardSync(
        lastSync: time2, runID: runID, now: epoch.addingTimeInterval(60)
    )

    #expect(recorded2.lastSync == time2)

    let fetched = try journal.boardSyncPoint()
    #expect(fetched?.lastSync == time2)
}

@Test("recordBoardSync without Act lease throws actLeaseLost")
func recordBoardSyncWithoutLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let lastSync = Date(timeIntervalSince1970: 1_789_000_000)

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.recordBoardSync(lastSync: lastSync, runID: runID, now: epoch)
    }
}

// MARK: - Card Read Tests

@Test("cards() returns all fixture Cards ordered by id")
func cardsReturnsAllOrdered() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let card1ID = try insertFixtureCard(journal, issueID: "CARD-1")
    let card2ID = try insertFixtureCard(journal, issueID: "CARD-2")

    let cards = try journal.cards()
    #expect(cards.count == 2)
    #expect(cards[0].id == card1ID)
    #expect(cards[1].id == card2ID)
    #expect(cards[0].issueID == "CARD-1")
    #expect(cards[1].issueID == "CARD-2")
}

@Test("card(issueID:) reads a Card by issue ID with all fields")
func cardByIssueID() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let cardID = try insertFixtureCard(journal, issueID: "CARD-123")

    let card = try journal.card(issueID: "CARD-123")
    #expect(card != nil)
    #expect(card?.id == cardID)
    #expect(card?.issueID == "CARD-123")
    #expect(card?.state == .todo)
    #expect(card?.cancelledFromState == nil)
    #expect(card?.waitingReason == nil)
}

@Test("card(id:) throws cardUnknown when Card id does not exist")
func cardByIDThrowsUnknown() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    #expect(throws: JournalError.cardUnknown(cardID: 9999)) {
        _ = try journal.card(id: 9999)
    }
}

// MARK: - Card Cancellation Tests

@Test("markCardCancelled on a Blocked Card yields cancelled state with previousState")
func markCardCancelledSetsState() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .blocked
    )

    _ = try journal.claimActLease(
        act: .author, runID: runID, mode: .real, now: epoch
    )

    let result = try journal.markCardCancelled(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
    )

    #expect(result.state == .cancelled)
    #expect(result.cancelledFromState == .blocked)

    let events = try journal.events(ofType: .cardCancelled)
    #expect(events.count == 1)
    guard case .cardCancelled(let eCardID, let issueID, let prevState) = events[0].event else {
        Issue.record("Event is not cardCancelled")
        return
    }
    #expect(eCardID == cardID)
    #expect(issueID == "CARD-1")
    #expect(prevState == .blocked)
}

@Test("markCardCancelled twice throws cardAlreadyCancelled")
func markCardCancelledTwiceThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .inProgress
    )
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    _ = try journal.markCardCancelled(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
    )

    #expect(throws: JournalError.cardAlreadyCancelled(cardID: cardID)) {
        try journal.markCardCancelled(
            cardID: cardID,
            runID: runID,
            act: .author,
            nightID: nil,
            now: epoch.addingTimeInterval(1)
        )
    }
}

@Test("restoreCancelledCard yields previous state with cleared column")
func restoreCancelledCardRestoresState() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .blocked
    )
    _ = try journal.claimActLease(
        act: .author, runID: runID, mode: .real, now: epoch
    )

    _ = try journal.markCardCancelled(
        cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
    )

    let restored = try journal.restoreCancelledCard(
        cardID: cardID, runID: runID, act: .author, nightID: nil,
        now: epoch.addingTimeInterval(1)
    )

    #expect(restored.state == .blocked)
    #expect(restored.cancelledFromState == nil)

    let events = try journal.events(ofType: .cardReopened)
    #expect(events.count == 1)
    guard case .cardReopened(let eCardID, let issueID, let restoredState) = events[0].event else {
        Issue.record("Event is not cardReopened")
        return
    }
    #expect(eCardID == cardID)
    #expect(issueID == "CARD-1")
    #expect(restoredState == .blocked)
}

@Test("restoreCancelledCard on non-cancelled Card throws cardNotCancelled")
func restoreNonCancelledThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCardWithState(
        journal, issueID: "CARD-1", state: .inProgress
    )
    _ = try journal.claimActLease(act: .author, runID: runID, mode: .real, now: epoch)

    #expect(throws: JournalError.cardNotCancelled(cardID: cardID)) {
        try journal.restoreCancelledCard(
            cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
        )
    }
}

@Test("markCardCancelled without Act lease throws actLeaseLost")
func markCardCancelledWithoutLease() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    let cardID = try insertFixtureCard(journal, issueID: "CARD-1")

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.markCardCancelled(
            cardID: cardID, runID: runID, act: .author, nightID: nil, now: epoch
        )
    }
}

// MARK: - Helpers

private func insertFixtureCard(_ journal: JournalStore, issueID: String) throws -> Int64 {
    try insertFixtureCardWithState(journal, issueID: issueID, state: .todo)
}

private func insertFixtureCardWithState(
    _ journal: JournalStore,
    issueID: String,
    state: CardState
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, \
            budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "main", "card", 1, state.rawValue, 0, JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}
