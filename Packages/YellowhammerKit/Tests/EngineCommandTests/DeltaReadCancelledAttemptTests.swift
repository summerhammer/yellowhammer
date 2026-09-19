import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// graph-execution/run-a-card, "A Card cancelled while it is running" (P8.9): the Delta Read applies
// Cancelled at the Act boundary. An open Attempt is not resumable state worth a budget, so it ends
// `cancelled` — no Attempt consumed, no Route excluded — and nothing more is posted to the Card.
// Nothing else about the Card is touched: a Cancel/reopen round trip buys no budget reset.

private let cancelRoute = Route(cli: "claude", model: "opus", effort: "high")!

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

@Suite("Delta Read: a Card cancelled while it is running (P8.9)")
struct DeltaReadCancelledAttemptTests {
    @Test("Cancel ends the open Attempt `cancelled`, excludes no Route, and aborts pending Outbox entries")
    func cancelEndsOpenAttemptAndAbortsOutbox() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .inProgress)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateCancelled, updatedAt: 1)])])
        let (read, runID) = try deltaRead(journal, board: board)

        let attempt = try journal.recordAttempt(cardID: cardID, route: cancelRoute, runID: runID)
        let pending = try acceptPendingWrite(journal, issueID: "card-1", runID: runID)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.cancelled.map(\.id) == [cardID])

        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.attempts.count == 1)
        let ended = try #require(history.attempts.first)
        #expect(ended.id == attempt.id)
        #expect(ended.result == "cancelled")
        #expect(ended.endedAt != nil)
        #expect(ended.consumedHow == "not consumed (Card cancelled)")

        let consumption = history.consumption(inEpoch: 0)
        #expect(consumption.consumed == 0)
        #expect(consumption.notConsumed == 1)
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)

        let entry = try #require(try journal.outboxEntry(id: pending.id))
        #expect(entry.state == .aborted)
        #expect(entry.lastError == "the Card is Cancelled; nothing is posted to it")

        // A following lane run does not dispatch it: only Todo Cards are runnable.
        let card = try journal.card(id: cardID)
        let lane = RepoLane(repository: card.repository, cards: [card])
        #expect(lane.runnable.isEmpty)
    }

    @Test("Cancel/reopen round trip: attempt history, consumption, budget_epoch and block_reason are unchanged")
    func cancelReopenRoundTripPreservesEverything() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .blocked)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateCancelled, updatedAt: 1)]),
            page(objects: [object("card-1", state: stateTodo, updatedAt: 2)])
        ])
        let (read, runID) = try deltaRead(journal, board: board)

        // A Card Blocked with a Block Reason and consumed Attempts.
        _ = try journal.transitionCard(
            cardID: cardID, to: .blocked, blockReason: .hardFailure, runID: runID, act: .build, nightID: nil
        )
        let attempt1 = try journal.recordAttempt(cardID: cardID, route: cancelRoute, runID: runID)
        _ = try journal.endAttempt(attemptID: attempt1.id, ending: .hardFailure(.exitStatus(1)), runID: runID)

        let beforeCard = try journal.card(id: cardID)
        let beforeHistory = try journal.attemptHistory(cardID: cardID)
        let beforeConsumption = beforeHistory.consumption(inEpoch: beforeCard.budgetEpoch)
        let beforeFailureCauses = try journal.events(ofType: .failureCauseRecorded)

        guard case .read(let cancelled) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(cancelled.cancelled.map(\.id) == [cardID])

        guard case .read(let reopened) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(reopened.reopened.map(\.id) == [cardID])

        let afterCard = try journal.card(id: cardID)
        #expect(afterCard.state == beforeCard.state)
        #expect(afterCard.blockReason == beforeCard.blockReason)
        #expect(afterCard.budgetEpoch == beforeCard.budgetEpoch)
        #expect(afterCard.cancelledFromState == nil)

        let afterHistory = try journal.attemptHistory(cardID: cardID)
        #expect(afterHistory.attempts.map(\.id) == beforeHistory.attempts.map(\.id))
        #expect(afterHistory.attempts.map(\.result) == beforeHistory.attempts.map(\.result))
        #expect(afterHistory.attempts.map { $0.rounds.count } == beforeHistory.attempts.map { $0.rounds.count })
        #expect(afterHistory.excludedRoutes == beforeHistory.excludedRoutes)

        let afterConsumption = afterHistory.consumption(inEpoch: afterCard.budgetEpoch)
        #expect(afterConsumption == beforeConsumption)

        let afterFailureCauses = try journal.events(ofType: .failureCauseRecorded)
        #expect(afterFailureCauses.count == beforeFailureCauses.count)
    }
}
