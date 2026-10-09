import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// board-projection/read-board-changes-by-delta, OQ142: a Work Card whose issue the Operator trashed, or
// archived while it was in play, inherits the Shelved rules but does not read as Shelved. It is dropped
// at the Act boundary without an Attempt, nothing is reconciled or posted for it, its Journal record is
// kept exactly as it stood, and un-trashing or unarchiving the issue restores it with no budget reset.

private let removalRoute = Route(cli: "claude", model: "opus", effort: "high")!

private func boardState(for state: CardState) -> BoardWorkflowState {
    BoardWorkflowState(id: BoardObjectID(rawValue: "s-\(state.rawValue)"), name: state.rawValue)
}

private func removedObject(_ id: String, state: CardState, how: CardRemoval, updatedAt: TimeInterval) -> BoardObject {
    object(
        id, state: boardState(for: state), updatedAt: updatedAt, archivedAt: updatedAt, isTrashed: how == .trashed
    )
}

/// Puts the Card into `state` the way the engine would, with the Journal columns each state carries.
private func settle(_ journal: JournalStore, cardID: Int64, in state: CardState, runID: RunID) throws {
    switch state {
    case .blocked:
        _ = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .routeFailure, runID: runID, act: .build, nightID: nil
        )
    case .waitingOnYou:
        _ = try journal.transitionCard(
            cardID: cardID, to: .waitingOnYou, waitingReason: .question, runID: runID, act: .build, nightID: nil
        )
    case .todo, .inProgress, .done, .shelved:
        break
    }
}

private func acceptPendingWrite(_ journal: JournalStore, issueID: String, runID: RunID) throws -> OutboxEntry {
    let write = BoardWrite.updateIssue(
        issue: BoardObjectID(rawValue: issueID), change: BoardIssueChange(workflowState: stateBlocked.id), undo: nil
    )
    let payload = try #require(String(data: try JSONEncoder().encode(write), encoding: .utf8))
    let entries = try journal.acceptOutbox(
        [OutboxDraft(clientID: UUID(), issueID: issueID, operation: write.operation, payload: payload)], runID: runID
    )
    return try #require(entries.first)
}

@Suite("Delta Read: a trashed or archived Work Card (OQ142)")
struct DeltaReadRemovedCardTests {
    static let inPlay: [CardState] = [.todo, .inProgress, .blocked, .waitingOnYou]

    @Test(
        "Removed in play: set aside once, nothing reconciled or posted; restored exactly as it stood",
        arguments: inPlay, [CardRemoval.trashed, .archived]
    )
    func removeAndRestore(state: CardState, how: CardRemoval) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: state == .inProgress ? .inProgress : .todo)
        let board = FakeReadingBoard([
            page(objects: [removedObject("card-1", state: state, how: how, updatedAt: 1)]),
            page(objects: [removedObject("card-1", state: state, how: how, updatedAt: 2)]),
            page(objects: [object("card-1", state: boardState(for: state), updatedAt: 3)])
        ])
        let (read, runID) = try deltaRead(journal, board: board)
        try settle(journal, cardID: cardID, in: state, runID: runID)
        let attempt = try journal.recordAttempt(cardID: cardID, route: removalRoute, runID: runID)
        let pending = try acceptPendingWrite(journal, issueID: "card-1", runID: runID)
        let before = try journal.card(id: cardID)

        guard case .read(let removed) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(removed.removed.map(\.card.id) == [cardID])
        #expect(removed.removed.map(\.how) == [how])
        #expect(removed.cardChanges.isEmpty)
        #expect(removed.restated.isEmpty)
        #expect(removed.shelved.isEmpty)
        let marked = try journal.card(id: cardID)
        #expect(marked.removedFromBoard == how)
        #expect(marked.state == before.state)
        // Dropped without an Attempt: the open one ends `cancelled`, consuming nothing.
        let ended = try #require(try journal.attemptHistory(cardID: cardID).attempts.first { $0.id == attempt.id })
        #expect(ended.result == "cancelled")
        #expect(try journal.attemptHistory(cardID: cardID).consumption(inEpoch: before.budgetEpoch).consumed == 0)
        // Nothing is posted to it.
        #expect(try journal.outboxEntry(id: pending.id)?.state == .aborted)

        guard case .read(let again) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(again.removed.isEmpty)
        #expect(again.cardChanges.isEmpty)
        #expect(try journal.events(ofType: .cardRemovedFromBoard).count == 1)

        guard case .read(let restored) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(restored.restoredToBoard.map(\.id) == [cardID])
        #expect(restored.restated.isEmpty)
        #expect(try journal.events(ofType: .cardRestoredToBoard).count == 1)
        try expectStandsAsBefore(try journal.card(id: cardID), before: before)
    }

    private func expectStandsAsBefore(_ after: CardRecord, before: CardRecord) throws {
        #expect(after.removedFromBoard == nil)
        #expect(after.state == before.state)
        #expect(after.blockReason == before.blockReason)
        #expect(after.waitingReason == before.waitingReason)
        #expect(after.budgetEpoch == before.budgetEpoch)
        #expect(after.stateVersion == before.stateVersion)
        #expect(after.unansweredNights == before.unansweredNights)
        #expect(after.failedAdoptions == before.failedAdoptions)
    }

    @Test("A trashed issue the board also reads Shelved is removed, not Shelved")
    func trashedShelvedIsNotShelved() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateShelved, updatedAt: 1, archivedAt: 1, isTrashed: true)])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.shelved.isEmpty)
        #expect(report.removed.map(\.how) == [.trashed])
        let card = try journal.card(id: cardID)
        #expect(card.state == .todo)
        #expect(card.removedFromBoard == .trashed)
    }

    @Test("A Card archived while Done or Shelved is not removed")
    func archivedOutOfPlayIsNotRemoved() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-done", state: .done)
        try insertCard(journal, issueID: "card-shelved", state: .shelved)
        let board = FakeReadingBoard([
            page(objects: [
                object("card-done", state: boardState(for: .done), archivedAt: 1),
                object("card-shelved", state: stateShelved, archivedAt: 1)
            ])
        ])
        let (read, _) = try deltaRead(journal, board: board)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.removed.isEmpty)
        #expect(try journal.cards().allSatisfy { $0.removedFromBoard == nil })
    }

    @Test("The Night Summary names each removed Work Card once, with how it was removed")
    func nightSummaryNamesEachRemovedCardOnce() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", state: .todo)
        try insertCard(journal, issueID: "card-2", state: .inProgress)
        let board = FakeReadingBoard([
            page(objects: [
                removedObject("card-1", state: .todo, how: .trashed, updatedAt: 1),
                removedObject("card-2", state: .inProgress, how: .archived, updatedAt: 1)
            ]),
            page(objects: [removedObject("card-1", state: .todo, how: .trashed, updatedAt: 2)]),
            page(objects: [object("card-2", state: boardState(for: .inProgress), updatedAt: 3)])
        ])
        let (read, _) = try deltaRead(journal, board: board)
        for _ in 0..<3 {
            _ = try await read.perform()
        }

        let lines = try NightSummary.removedCardLines(events: try journal.events(), journal: journal)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("[ENG-card-1]("))
        #expect(lines[0].contains(" was trashed on the board."))
        #expect(lines[0].contains("set aside"))
        #expect(lines[1].hasPrefix("[ENG-card-2]("))
        #expect(lines[1].contains(" was archived on the board."))
        #expect(lines[1].contains("restored this Night"))
    }
}
