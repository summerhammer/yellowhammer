import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// board-projection (P5.8): a Journal-side Card state transition persists state and reasons and bumps
// state_version; a no-op transition (same state, same reasons) bumps nothing and logs nothing; Shelved
// is refused both as a target and as a source (glossary → Shelved: Yellowhammer reads it and never
// writes it); Waiting on You and Blocked each require the reason that backs them; leaving either clears
// its column; cardsWithUnpostedState and recordCardBoardState round-trip the board's confirmation.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-card-transition-\(UUID().uuidString)", directoryHint: .isDirectory)
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

@discardableResult
private func insertFixtureCard(
    _ journal: JournalStore, issueID: String = "CARD-1", repository: String = "main"
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
                cycleID, issueID, repository, "card", 1, CardState.todo.rawValue, 0, JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

/// Claims the Act-scoped Lease (so `transitionCard` can be called) and inserts one fixture Card.
private func fixtureCard(_ journal: JournalStore) throws -> (cardID: Int64, runID: RunID) {
    let runID = RunID()
    _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: epoch)
    let cardID = try insertFixtureCard(journal)
    return (cardID, runID)
}

@Suite("Card state transitions")
struct CardTransitionTests {
    @Test("A transition persists state and reasons and bumps state_version")
    func transitionPersistsAndBumpsVersion() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)

        let record = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .checkFailure,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        #expect(record.state == .blocked)
        #expect(record.blockReason == BlockReason.checkFailure.rawValue)
        #expect(record.stateVersion == 1)
        #expect(record.boardStateVersion == nil)

        let events = try journal.events(ofType: .cardStateTransitioned)
        #expect(events.count == 1)
        guard case .cardStateTransitioned(let eventCardID, _, let from, let to, let waiting, let blocked) =
            events[0].event else {
            Issue.record("expected cardStateTransitioned")
            return
        }
        #expect(eventCardID == cardID)
        #expect(from == .todo)
        #expect(to == .blocked)
        #expect(waiting == nil)
        #expect(blocked == .checkFailure)
    }

    @Test("A no-op transition — same state, same reasons — bumps nothing and logs nothing")
    func noOpTransitionBumpsNothing() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        let first = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .checkFailure,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        let second = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .checkFailure,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        #expect(second == first)
        #expect(second.stateVersion == 1)
        #expect(try journal.events(ofType: .cardStateTransitioned).count == 1)
    }

    @Test("Shelved is refused as a target")
    func shelvedTargetThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)

        #expect(throws: JournalError.shelvedIsNeverWritten(cardID: cardID)) {
            try journal.transitionCard(
                cardID: cardID, to: .shelved, runID: runID, act: .build, nightID: nil, now: epoch
            )
        }
    }

    @Test("A shelved Card cannot be transitioned")
    func shelvedCardThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        _ = try journal.markCardShelved(cardID: cardID, runID: runID, act: .build, nightID: nil, now: epoch)

        #expect(throws: JournalError.cardAlreadyShelved(cardID: cardID)) {
            try journal.transitionCard(cardID: cardID, to: .todo, runID: runID, act: .build, nightID: nil, now: epoch)
        }
    }

    @Test("Waiting on You without a waiting reason throws")
    func waitingOnYouWithoutReasonThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)

        #expect(throws: JournalError.waitingOnYouUnbacked(cardID: cardID)) {
            try journal.transitionCard(
                cardID: cardID, to: .waitingOnYou, runID: runID, act: .build, nightID: nil, now: epoch
            )
        }
    }

    @Test("Blocked without a Block Reason throws")
    func blockedWithoutReasonThrows() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)

        #expect(throws: JournalError.blockReasonRequired(cardID: cardID)) {
            try journal.transitionCard(
                cardID: cardID, to: .blocked, runID: runID, act: .build, nightID: nil, now: epoch
            )
        }
    }

    @Test("Leaving Waiting on You clears waiting_reason")
    func leavingWaitingOnYouClearsReason() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        _ = try journal.transitionCard(
            cardID: cardID, to: .waitingOnYou, waitingReason: .question,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        let record = try journal.transitionCard(
            cardID: cardID, to: .todo, runID: runID, act: .build, nightID: nil, now: epoch
        )

        #expect(record.state == .todo)
        #expect(record.waitingReason == nil)
    }

    @Test("Leaving Blocked clears block_reason")
    func leavingBlockedClearsReason() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        _ = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .reviewerRejection,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        let record = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: epoch
        )

        #expect(record.state == .inProgress)
        #expect(record.blockReason == nil)
    }

    @Test("Blocked entered from Waiting on You clears waiting_reason and sets block_reason")
    func blockedFromWaitingOnYouSwapsReasons() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        _ = try journal.transitionCard(
            cardID: cardID, to: .waitingOnYou, waitingReason: .question,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        let record = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .replyOverdue,
            runID: runID, act: .build, nightID: nil, now: epoch
        )

        #expect(record.waitingReason == nil)
        #expect(record.blockReason == BlockReason.replyOverdue.rawValue)
    }

    @Test("cardsWithUnpostedState and recordCardBoardState round-trip the board's confirmation")
    func unpostedStateRoundTrips() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: epoch
        )

        let unposted = try journal.cardsWithUnpostedState()
        #expect(unposted.map(\.id) == [cardID])

        try journal.recordCardBoardState(cardID: cardID, version: 1, runID: runID, now: epoch)

        #expect(try journal.cardsWithUnpostedState().isEmpty)
        #expect(try journal.card(id: cardID).boardStateVersion == 1)

        // A stale confirmation does not regress the recorded version.
        try journal.recordCardBoardState(cardID: cardID, version: 0, runID: runID, now: epoch)
        #expect(try journal.card(id: cardID).boardStateVersion == 1)
    }

    @Test("A Shelved Card never appears among cards with unposted state")
    func shelvedCardExcludedFromUnpostedState() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: epoch
        )
        _ = try journal.markCardShelved(cardID: cardID, runID: runID, act: .build, nightID: nil, now: epoch)

        #expect(try journal.cardsWithUnpostedState().isEmpty)
    }

    @Test("A freshly authored Card, never transitioned, is not among cards with unposted state")
    func freshlyAuthoredCardExcludedFromUnpostedState() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        let (cardID, runID) = try fixtureCard(journal)
        #expect(try journal.card(id: cardID).stateVersion == 0)
        #expect(try journal.card(id: cardID).boardStateVersion == nil)

        #expect(try journal.cardsWithUnpostedState().isEmpty)

        // Its first Journal transition is a write of its own, and is unposted until the board confirms it.
        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: epoch
        )
        #expect(try journal.cardsWithUnpostedState().map(\.id) == [cardID])
    }

    @Test("The card table has the state-version columns")
    func cardTableHasStateVersionColumns() throws {
        let fixture = try JournalFixture()
        let journal = try fixture.open()
        _ = try fixtureCard(journal)

        let columns = try journal.read { try $0.columns(in: "card") }.map(\.name)
        #expect(columns.contains("state_version"))
        #expect(columns.contains("board_state_version"))
    }
}
