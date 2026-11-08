import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// board-projection / moved-out-of-done (ruling OQ199, 2026-11-08): a Done Work Card the board reads in a state
// that is neither completed nor cancelled is recorded Blocked `moved out of Done`, Journal-only; the build
// Act's repost writes Blocked to the board, and detaches the Card when its Feature has closed.

private let doneStateDone = BoardWorkflowState(
    id: BoardObjectID(rawValue: "s-done"), name: "Done", category: .completed
)
private let stateInProgress = BoardWorkflowState(
    id: BoardObjectID(rawValue: "s-in-progress"), name: "In Progress", category: .started
)
private let stateTodoUnstarted = BoardWorkflowState(
    id: BoardObjectID(rawValue: "s-todo"), name: "Todo", category: .unstarted
)

/// A Card the engine moved to Done and the board confirmed, as a Yellowhammer-written Done is.
private func confirmedDoneCard(_ journal: JournalStore, issueID: String, runID: RunID) throws -> Int64 {
    let cardID = try insertCard(journal, issueID: issueID, state: .todo)
    let done = try journal.transitionCard(cardID: cardID, to: .done, runID: runID, act: .build, nightID: nil)
    try journal.recordCardBoardState(cardID: cardID, version: done.stateVersion, runID: runID)
    return cardID
}

private func acceptPendingStateWrite(
    _ journal: JournalStore, issueID: String, target: BoardWorkflowState, runID: RunID
) throws {
    let write = BoardWrite.updateIssue(
        issue: BoardObjectID(rawValue: issueID), change: BoardIssueChange(workflowState: target.id), undo: nil
    )
    let payload = try #require(String(data: try JSONEncoder().encode(write), encoding: .utf8))
    _ = try journal.acceptOutbox(
        [OutboxDraft(clientID: UUID(), issueID: issueID, operation: write.operation, payload: payload)],
        runID: runID
    )
}

private func archive(_ journal: JournalStore, cardID: Int64, runID: RunID) throws {
    let cycleID = try journal.card(id: cardID).cycleID
    let featureID = try journal.read { db in
        try #require(try Int64.fetchOne(db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID]))
    }
    try journal.archiveCycle(cycleID: cycleID, featureID: featureID, closedBy: .completion, runID: runID)
}

@Suite("Delta Read: a Done Work Card moved out of Done (OQ199)")
struct DeltaReadMovedOutOfDoneTests {
    @Test("Read in Todo or In Progress: Blocked `moved out of Done`, counters kept, one transition, no restate",
          arguments: [stateTodoUnstarted, stateInProgress])
    func movedOutRecordsBlocked(boardState: BoardWorkflowState) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([page(objects: [object("card-1", state: boardState, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let cardID = try confirmedDoneCard(journal, issueID: "card-1", runID: runID)
        try journal.write { db in
            try db.execute(sql: "UPDATE card SET budget_epoch = 2 WHERE id = ?", arguments: [cardID])
        }
        let before = try journal.card(id: cardID)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        let card = try journal.card(id: cardID)
        #expect(report.movedOutOfDone.map(\.id) == [cardID])
        #expect(report.restated.isEmpty)
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.movedOutOfDone.rawValue)
        #expect(card.budgetEpoch == 2)
        #expect(card.stateVersion == before.stateVersion + 1)
        #expect(card.boardStateVersion == before.boardStateVersion)
        let toBlocked = try journal.events(ofType: .cardStateTransitioned).filter {
            if case .cardStateTransitioned(_, _, _, .blocked, _, _) = $0.event { return true }
            return false
        }
        #expect(toBlocked.count == 1)
        #expect(try journal.events(ofType: .cardRestated).isEmpty)
    }

    @Test("Read in a canceled-type state, a Done Card is Shelved as from any other state")
    func canceledIsShelved() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateCanceledByCategory, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let cardID = try confirmedDoneCard(journal, issueID: "card-1", runID: runID)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.shelved.map(\.id) == [cardID])
        #expect(report.movedOutOfDone.isEmpty)
        #expect(try journal.card(id: cardID).state == .shelved)
    }

    @Test("A Done write still pending, or a Done the board has not confirmed, is not a move out of Done")
    func unconfirmedDoneIsNotMovedOut() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([page(objects: [
            object("pending", state: stateInProgress, updatedAt: 1),
            object("unconfirmed", state: stateInProgress, updatedAt: 1)
        ])])
        let (read, runID) = try deltaRead(journal, board: board)
        let pending = try confirmedDoneCard(journal, issueID: "pending", runID: runID)
        try acceptPendingStateWrite(journal, issueID: "pending", target: doneStateDone, runID: runID)
        let unconfirmed = try insertCard(journal, issueID: "unconfirmed", state: .todo)
        _ = try journal.transitionCard(cardID: unconfirmed, to: .done, runID: runID, act: .build, nightID: nil)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.movedOutOfDone.isEmpty)
        #expect(try journal.card(id: pending).state == .done)
        #expect(try journal.card(id: unconfirmed).state == .done)
    }

    @Test("An Operator Done Card moved out is Blocked and no longer Operator Done; re-ready resets the budget")
    func operatorDoneMovedOutThenReReadied() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: doneStateDone, updatedAt: 1)]),
            page(objects: [object("card-1", state: stateInProgress, updatedAt: 2)]),
            page(objects: [object("card-1", state: stateTodoUnstarted, updatedAt: 3)])
        ])
        let (read, _) = try deltaRead(journal, board: board)
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)

        _ = try await read.perform()
        #expect(try journal.isOperatorDone(cardID: cardID))

        _ = try await read.perform()
        let blocked = try journal.card(id: cardID)
        #expect(blocked.state == .blocked)
        #expect(blocked.blockReason == BlockReason.movedOutOfDone.rawValue)
        #expect(try !journal.isOperatorDone(cardID: cardID))

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        let ready = try journal.card(id: cardID)
        #expect(report.reReadied.map(\.id) == [cardID])
        #expect(ready.state == .todo)
        #expect(ready.budgetEpoch == blocked.budgetEpoch + 1)
    }

    @Test("The repost writes Blocked, and clears the parent only when the Cycle is archived", arguments: [false, true])
    func repostProjectsBlocked(archived: Bool) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let inProgress = BoardWorkflowState(
            id: try scope.id(for: .inProgress), name: "In Progress", category: .started
        )
        let issue = await boards.writing.seed(issue: "card-1", description: nil)
        let reading = FakeReadingBoard([page(objects: [object("card-1", state: inProgress, updatedAt: 1)])])
        try await reading.readThrough(boards)
        let (read, readRun) = try deltaRead(journal, board: reading)
        let cardID = try confirmedDoneCard(journal, issueID: "card-1", runID: readRun)
        if archived { try archive(journal, cardID: cardID, runID: readRun) }
        _ = try await read.perform()
        try journal.releaseActLease(runID: readRun)
        let baseline = await boards.writing.writeLog.count

        let projection = BoardStateProjection(
            journal: journal, outbox: try outbox(journal, board: boards.writing), scope: scope
        )
        let outcomes = try await projection.repost()

        #expect(outcomes.count == 1)
        let writes = await boards.writing.writes(to: issue, since: baseline)
        guard case .update(let change)? = writes.last else {
            Issue.record("expected a state write")
            return
        }
        #expect(change.workflowState == scope.states[.blocked])
        #expect(change.parent == (archived ? .clear : nil))
        #expect(try journal.card(id: cardID).boardStateVersion == journal.card(id: cardID).stateVersion)
    }
}
