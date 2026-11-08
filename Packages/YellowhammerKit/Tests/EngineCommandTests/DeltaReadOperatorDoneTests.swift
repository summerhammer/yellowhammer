import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// board-projection / operator-done (ruling OQ199, 2026-11-08): a Work Card the board shows in a completed-type
// state, which the Journal holds neither as Done nor already as done by the Operator, and which no write of
// Yellowhammer's still pending for the Card targets, is Done by the Operator — from any state, in every Act's
// read. These run against an in-memory Linear stand-in.

private let stateDone = BoardWorkflowState(id: BoardObjectID(rawValue: "s-done"), name: "Done", category: .completed)
private let stateMerged = BoardWorkflowState(
    id: BoardObjectID(rawValue: "s-merged"), name: "Merged", category: .completed
)
private let doneRoute = Route(cli: "claude", model: "opus", effort: "high")!

private func acceptStateWrite(
    _ journal: JournalStore, issueID: String, target: BoardWorkflowState, expected: BoardWorkflowState? = nil,
    runID: RunID
) throws -> OutboxEntry {
    let write = BoardWrite.updateIssue(
        issue: BoardObjectID(rawValue: issueID), change: BoardIssueChange(workflowState: target.id), undo: nil
    )
    let payload = try #require(String(data: try JSONEncoder().encode(write), encoding: .utf8))
    let entries = try journal.acceptOutbox(
        [OutboxDraft(
            clientID: UUID(), issueID: issueID, operation: write.operation, payload: payload,
            expectedStateID: expected?.id.rawValue
        )],
        runID: runID
    )
    return try #require(entries.first)
}

private func acceptComment(_ journal: JournalStore, issueID: String, runID: RunID) throws -> OutboxEntry {
    let write = BoardWrite.createComment(issue: BoardObjectID(rawValue: issueID), body: "hello")
    let payload = try #require(String(data: try JSONEncoder().encode(write), encoding: .utf8))
    let entries = try journal.acceptOutbox(
        [OutboxDraft(clientID: UUID(), issueID: issueID, operation: write.operation, payload: payload)], runID: runID
    )
    return try #require(entries.first)
}

@Suite("Delta Read: a Work Card the Operator moved to Done (OQ199)")
struct DeltaReadOperatorDoneTests {
    @Test(
        "Read in a completed-type state from any state: Done with the marker, nothing reposted",
        arguments: [CardState.todo, .inProgress, .blocked, .waitingOnYou, .shelved]
    )
    func operatorDoneFromAnyState(from: CardState) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: from == .inProgress ? .inProgress : .todo)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateDone, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let attempt = from == .inProgress
            ? try journal.recordAttempt(cardID: cardID, route: doneRoute, runID: runID) : nil
        switch from {
        case .blocked:
            _ = try journal.transitionCard(
                cardID: cardID, to: .blocked, blockReason: .routeFailure, runID: runID, act: .build, nightID: nil
            )
        case .waitingOnYou:
            _ = try journal.transitionCard(
                cardID: cardID, to: .waitingOnYou, waitingReason: .question, runID: runID, act: .build, nightID: nil
            )
        case .shelved:
            _ = try journal.markCardShelved(cardID: cardID, runID: runID, act: .build, nightID: nil)
        case .todo, .inProgress, .done:
            break
        }
        let before = try journal.card(id: cardID)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.operatorDone.map(\.id) == [cardID])
        #expect(report.restated.isEmpty)
        let card = try journal.card(id: cardID)
        #expect(card.state == .done)
        #expect(card.waitingReason == nil)
        #expect(card.blockReason == nil)
        #expect(card.stateVersion == before.stateVersion + 1)
        #expect(card.boardStateVersion == card.stateVersion)
        #expect(try journal.cardsWithUnpostedState().isEmpty)
        #expect(try journal.isOperatorDone(cardID: cardID))
        #expect(try journal.events(ofType: .cardRestated).isEmpty)
        let events = try journal.events(ofType: .cardOperatorDone)
        #expect(events.count == 1)
        guard case .cardOperatorDone(_, _, let previous, let waiting, let block)? = events.first?.event else {
            Issue.record("expected cardOperatorDone")
            return
        }
        // A Shelved Card is restored first, to the state it held, and that is its previous state.
        #expect(previous == (from == .shelved ? .todo : from))
        #expect(waiting == (from == .waitingOnYou ? .question : nil))
        #expect(block == (from == .blocked ? .routeFailure : nil))
        #expect(try journal.events(ofType: .cardReopened).count == (from == .shelved ? 1 : 0))
        if let attempt {
            try expectCancelledAttempt(journal, cardID: cardID, attemptID: attempt.id)
        }
    }

    private func expectCancelledAttempt(_ journal: JournalStore, cardID: Int64, attemptID: Int64) throws {
        let history = try journal.attemptHistory(cardID: cardID)
        let ended = try #require(history.attempts.first)
        #expect(ended.id == attemptID)
        #expect(ended.result == "cancelled")
        #expect(ended.endedAt != nil)
        #expect(history.consumption(inEpoch: 0).consumed == 0)
        #expect(history.consumption(inEpoch: 0).notConsumed == 1)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
    }

    @Test("A state write of Yellowhammer's own still pending for the board's completed state is not the Operator's")
    func pendingWriteToTheBoardsStateIsYellowhammers() async throws {
        for expected in [nil, stateTodo] as [BoardWorkflowState?] {
            let fixture = try OutboxJournalFixture()
            let journal = try fixture.open()
            let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
            let board = FakeReadingBoard([page(objects: [object("card-1", state: stateDone, updatedAt: 1)])])
            let (read, runID) = try deltaRead(journal, board: board)
            let pending = try acceptStateWrite(
                journal, issueID: "card-1", target: stateDone, expected: expected, runID: runID
            )

            guard case .read(let report) = try await read.perform() else {
                Issue.record("expected a read")
                return
            }

            #expect(report.operatorDone.isEmpty)
            #expect(try journal.card(id: cardID).state == .todo)
            #expect(try journal.events(ofType: .cardOperatorDone).isEmpty)
            #expect(try journal.outboxEntry(id: pending.id)?.state == .pending)
        }
    }

    @Test("Operator Done aborts the Card's pending state writes and leaves its comment writes pending")
    func abortsStateWritesOnly() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateDone, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let stateWrite = try acceptStateWrite(journal, issueID: "card-1", target: stateBlocked, runID: runID)
        let comment = try acceptComment(journal, issueID: "card-1", runID: runID)

        _ = try await read.perform()

        #expect(try journal.card(id: cardID).state == .done)
        #expect(try journal.outboxEntry(id: stateWrite.id)?.state == .aborted)
        #expect(try journal.outboxEntry(id: comment.id)?.state == .pending)
    }

    // Issue #736's shape: the settle's auto-Block was decided against Todo while the Operator had already moved the
    // Card to Done. The read supersedes the stale write, then reads the Done as the Operator's — without trying to
    // abort the entry it has just superseded.
    @Test("A stale conditioned Blocked write the board outran is superseded, and the Done is the Operator's")
    func staleConditionedWriteIsSupersededThenOperatorDone() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateDone, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let stale = try acceptStateWrite(
            journal, issueID: "card-1", target: stateBlocked, expected: stateTodo, runID: runID
        )

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.operatorDone.map(\.id) == [cardID])
        #expect(try journal.card(id: cardID).state == .done)
        #expect(try journal.outboxEntry(id: stale.id)?.state == .superseded)
        #expect(try journal.events(ofType: .boardWriteSuperseded).count == 1)
        #expect(try journal.events(ofType: .cardRestated).isEmpty)
        #expect(try journal.cardsWithUnpostedState().isEmpty)
    }

    @Test("A Done Card read in another completed-type state is no divergence")
    func doneReadInAnotherCompletedStateIsNotRestated() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .done)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateMerged, updatedAt: 1)])])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.restated.isEmpty)
        #expect(report.operatorDone.isEmpty)
        #expect(try journal.events(ofType: .cardRestated).isEmpty)
        #expect(try journal.events(ofType: .cardOperatorDone).isEmpty)
        #expect(try !journal.isOperatorDone(cardID: cardID))
    }

    @Test("A replayed observation finds the Card already Done and records nothing twice")
    func replayIsIdempotent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        _ = try insertCard(journal, issueID: "card-1", state: .todo)
        let doneObject = object("card-1", state: stateDone, updatedAt: 1)
        let board = FakeReadingBoard([page(objects: [doneObject]), page(objects: [doneObject])])
        let (read, _) = try deltaRead(journal, board: board)

        _ = try await read.perform()
        _ = try await read.perform()

        #expect(try journal.events(ofType: .cardOperatorDone).count == 1)
        #expect(try journal.events(ofType: .cardRestated).isEmpty)
    }

    @Test("A Card Blocked `feature completed` in an archived Cycle, later read Done, is no longer un-adopted")
    func detachedBlockedCardReadDone() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateDone, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)
        _ = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .featureCompleted, runID: runID, act: .build, nightID: nil
        )
        let cycleID = try journal.card(id: cardID).cycleID
        let featureID = try journal.read { db in
            try #require(try Int64.fetchOne(db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID]))
        }
        try journal.archiveCycle(cycleID: cycleID, featureID: featureID, closedBy: .completion, runID: runID)
        #expect(try journal.blockedCardsLeftByClosedFeatures().map(\.id) == [cardID])

        _ = try await read.perform()

        #expect(try journal.card(id: cardID).state == .done)
        #expect(try journal.blockedCardsLeftByClosedFeatures().isEmpty)
        #expect(try journal.unadoptedCards(asOf: NightStart(rawValue: "2026-11-08")!).isEmpty)
        #expect(try journal.isOperatorDone(cardID: cardID))
    }
}
