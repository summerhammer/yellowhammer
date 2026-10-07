import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

/// Inserts a fixture Card already Blocked under `reason`, with a non-zero `budget_epoch` so the test can
/// assert the Block Reason selects the correct epoch policy.
@discardableResult
private func insertBlockedCard(
    _ journal: JournalStore, issueID: String, reason: BlockReason, budgetEpoch: Int = 2
) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["feature-of-\(issueID)", "selected", JournalStore.timestamp(deltaEpoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(deltaEpoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (
                cycle_id, issue_id, repository, kind, authored_order, state, block_reason, budget_epoch, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, "backend", "impl", 1, CardState.blocked.rawValue, reason.rawValue, budgetEpoch,
                JournalStore.timestamp(deltaEpoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

private let reReadyRoute = Route(cli: "claude", model: "opus", effort: "high")!
private let resettingReasons: Set<BlockReason> = [
    .reviewerRejection, .checkFailure, .routeFailure, .hostCrash,
    .engineFault, .operatorAbort, .failureRecurrence
]

@Suite("Delta Read re-ready")
struct DeltaReadReReadyTests {
    @Test("Linear Todo re-readies all ten Block Reasons with their budget policy", arguments: BlockReason.allCases)
    func knownBlockIsReReadied(reason: BlockReason) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: reason)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let oldAttempt = try journal.recordAttempt(
            cardID: cardID, route: reReadyRoute, runID: runID, now: deltaEpoch
        )
        let oldRound = try journal.recordRound(
            attemptID: oldAttempt.id, lens: .review, verdict: "changes-requested",
            requestedChanges: nil, judgedCommit: nil, runID: runID, now: deltaEpoch
        )
        try journal.endAttempt(
            attemptID: oldAttempt.id, ending: .hardFailure(.exitStatus(1)), runID: runID, now: deltaEpoch
        )
        let oldHistory = try journal.attemptHistory(cardID: cardID)

        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        let resets = resettingReasons.contains(reason)
        let card = try journal.card(id: cardID)
        #expect(report.reReadied.map(\.issueID) == ["card-1"])
        #expect(report.reReadied.first?.budgetEpoch == (resets ? 3 : 2))
        #expect(report.restated.isEmpty)
        #expect(card.state == .todo)
        #expect(card.blockReason == nil)
        #expect(card.budgetEpoch == (resets ? 3 : 2))
        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.attempts == oldHistory.attempts)
        #expect(history.attempts.flatMap(\.rounds) == [oldRound])
        #expect(history.consumption(inEpoch: card.budgetEpoch).consumed == (resets ? 0 : 1))
        #expect(try journal.excludedRoutes(cardID: cardID) == (resets ? [] : [reReadyRoute]))
        #expect(history.excludedRoutes == [reReadyRoute], "historical exclusions remain")
        #expect(try journal.events(ofType: .budgetEpochReset).count == (resets ? 1 : 0))

        if resets {
            let fresh = try journal.recordAttempt(
                cardID: cardID, route: reReadyRoute, runID: runID, now: deltaEpoch
            )
            #expect(fresh.budgetEpoch == 3)
            #expect(try journal.attemptHistory(cardID: cardID).attempts.last?.rounds.isEmpty == true)
        }
    }

    @Test("Missing and unknown Block Reasons are restated", arguments: [nil, "unknown"] as [String?])
    func unrecognizedReasonIsRestated(reason: String?) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .routeFailure)
        try journal.write { db in
            try db.execute(sql: "UPDATE card SET block_reason = ? WHERE id = ?", arguments: [reason, cardID])
        }
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, _) = try deltaRead(journal, board: board)
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected read")
            return
        }
        #expect(report.reReadied.isEmpty)
        #expect(report.restated.map(\.card.issueID) == ["card-1"])
        #expect(try journal.card(id: cardID).budgetEpoch == 2)
    }

    @Test("A move to another Linear state does not re-ready")
    func otherStateIsRestated() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .routeFailure)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateWaiting)])])
        let (read, _) = try deltaRead(journal, board: board)
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected read")
            return
        }
        #expect(report.reReadied.isEmpty)
        #expect(report.restated.map(\.card.issueID) == ["card-1"])
        #expect(try journal.card(id: cardID).state == .blocked)
    }

    @Test("A pending board write prevents re-ready and epoch reset")
    func pendingWritePreventsReReady() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .routeFailure)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let pending = BoardWrite.updateIssue(
            issue: BoardObjectID(rawValue: "card-1"),
            change: BoardIssueChange(workflowState: stateBlocked.id), undo: nil
        )
        let payload = try #require(String(data: try JSONEncoder().encode(pending), encoding: .utf8))
        _ = try journal.acceptOutbox(
            [OutboxDraft(clientID: UUID(), issueID: "card-1", operation: pending.operation, payload: payload)],
            runID: runID, now: deltaEpoch
        )
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected read")
            return
        }
        #expect(report.reReadied.isEmpty)
        #expect(report.restated.isEmpty)
        #expect(try journal.card(id: cardID).state == .blocked)
        #expect(try journal.card(id: cardID).budgetEpoch == 2)
    }

    @Test("An open Attempt prevents an epoch-resetting re-ready without partial state")
    func openAttemptRefusesReReady() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .routeFailure)
        let board = FakeReadingBoard([page(objects: [object("card-1", state: stateTodo)])])
        let (read, runID) = try deltaRead(journal, board: board)
        let attempt = try journal.recordAttempt(cardID: cardID, route: reReadyRoute, runID: runID, now: deltaEpoch)
        await #expect(throws: JournalError.attemptStillOpen(cardID: cardID, attemptID: attempt.id)) {
            try await read.perform()
        }
        #expect(try journal.card(id: cardID).state == .blocked)
        #expect(try journal.card(id: cardID).budgetEpoch == 2)
        #expect(try journal.events(ofType: .budgetEpochReset).isEmpty)
        #expect(try journal.events(ofType: .cardStateTransitioned).isEmpty)
    }

    @Test("A failed state write rolls back its epoch reset; retry commits once")
    func failedTransitionRollsBackAndRetryResetsOnce() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertBlockedCard(journal, issueID: "card-1", reason: .routeFailure)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateTodo)]),
            page(objects: [object("card-1", state: stateTodo)])
        ])
        let (read, runID) = try deltaRead(journal, board: board)
        try journal.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_transition BEFORE UPDATE OF state ON card
                BEGIN SELECT RAISE(ABORT, 'fixture transition failure'); END
                """)
        }
        await #expect(throws: DatabaseError.self) { try await read.perform() }
        #expect(try journal.card(id: cardID).state == .blocked)
        #expect(try journal.card(id: cardID).budgetEpoch == 2)
        #expect(try journal.events(ofType: .budgetEpochReset).isEmpty)
        try journal.write { db in try db.execute(sql: "DROP TRIGGER fail_transition") }
        _ = try await read.perform()
        let retried = try journal.transitionCard(
            cardID: cardID, to: .todo, resetBudgetReason: "re-readied",
            runID: runID, act: .build, nightID: nil, now: deltaEpoch
        )
        #expect(retried.state == .todo)
        #expect(retried.budgetEpoch == 3, "a repeated transition never resets twice")
        #expect(try journal.events(ofType: .budgetEpochReset).count == 1)
        #expect(try journal.events(ofType: .cardStateTransitioned).count == 1)
    }
}
