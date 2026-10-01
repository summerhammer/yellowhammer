import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Operator's abort vocabulary and request record (Stop the engine, P18.10): an `aborted` Attempt
// consumes nothing but still decides the Block Reason, and the request is written without the Act Lease.

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let routeA = Route(cli: "claude", model: "opus", effort: "high")!

/// One open Cycle with `count` Cards; returns the Card ids.
private func insertCards(_ journal: JournalStore, count: Int, archived: Bool = false) throws -> [Int64] {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["ENG-\(UUID().uuidString)", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at, archived_at) VALUES (?, ?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch), archived ? JournalStore.timestamp(epoch) : nil]
        )
        let cycleID = db.lastInsertedRowID
        var ids: [Int64] = []
        for order in 1...count {
            try db.execute(
                sql: """
                INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, "C-\(UUID().uuidString)", "backend", "impl", order, CardState.todo.rawValue, 0,
                    JournalStore.timestamp(epoch)
                ]
            )
            ids.append(db.lastInsertedRowID)
        }
        return ids
    }
}

private func claimLease(_ journal: JournalStore, runID: RunID) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: epoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

@Test("An aborted Attempt is not consumed and is counted as not consumed")
func abortedAttemptIsNotConsumed() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertCards(journal, count: 1)[0]
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .aborted, runID: runID, act: .build, now: epoch.addingTimeInterval(1)
    )

    let consumption = try journal.attemptHistory(cardID: cardID).consumption(inEpoch: 0)

    #expect(consumption.consumed == 0)
    #expect(consumption.notConsumed == 1)
}

@Test("An aborted last Attempt blocks operator abort; a later hard failure wins")
func abortedLastAttemptBlocksOperatorAbort() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertCards(journal, count: 1)[0]
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: first.id, ending: .aborted, runID: runID, act: .build, now: epoch.addingTimeInterval(1)
    )
    #expect(try journal.attemptHistory(cardID: cardID).blockReason(inEpoch: 0) == .operatorAbort)

    let second = try journal.recordAttempt(
        cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(2)
    )
    _ = try journal.endAttempt(
        attemptID: second.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(3)
    )
    #expect(try journal.attemptHistory(cardID: cardID).blockReason(inEpoch: 0) == .hardFailure)
}

@Test("The schema has the operator_abort_request table")
func operatorAbortSchemaHasTable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    let exists = try journal.read { db in try db.tableExists("operator_abort_request") }
    #expect(exists)
}

@Test("requestOperatorAbort records for an open Attempt, is idempotent, and writes nothing for an ended one")
func requestOperatorAbortOpenAndEnded() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertCards(journal, count: 1)[0]
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let open = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    #expect(try journal.isOperatorAbortRequested(attemptID: open.id) == false)
    #expect(try journal.requestOperatorAbort(attemptID: open.id, now: epoch))
    #expect(try journal.requestOperatorAbort(attemptID: open.id, now: epoch.addingTimeInterval(5)))
    #expect(try journal.isOperatorAbortRequested(attemptID: open.id))
    let rows = try journal.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM operator_abort_request") }
    #expect(rows == 1)

    _ = try journal.endAttempt(
        attemptID: open.id, ending: .aborted, runID: runID, act: .build, now: epoch.addingTimeInterval(9)
    )
    let ended = try journal.recordAttempt(
        cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(10)
    )
    _ = try journal.endAttempt(
        attemptID: ended.id, ending: .success, runID: runID, act: .build, now: epoch.addingTimeInterval(11)
    )
    #expect(try journal.requestOperatorAbort(attemptID: ended.id) == false)
    #expect(try journal.isOperatorAbortRequested(attemptID: ended.id) == false)
    #expect(try journal.attempt(id: ended.id)?.isOpen == false)
    #expect(try journal.attempt(id: 9999) == nil)
    #expect(throws: JournalError.self) { try journal.requestOperatorAbort(attemptID: 9999) }
}

@Test("requestOperatorAbortOfRunningAttempts requests only open Attempts of the in-flight Cycle, with no Act Lease")
func requestOperatorAbortOfRunningAttemptsScope() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let archivedCard = try insertCards(journal, count: 1, archived: true)[0]
    let cards = try insertCards(journal, count: 3)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let stale = try journal.recordAttempt(cardID: archivedCard, route: routeA, runID: runID, now: epoch)
    let running = try journal.recordAttempt(cardID: cards[0], route: routeA, runID: runID, now: epoch)
    let finished = try journal.recordAttempt(cardID: cards[1], route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: finished.id, ending: .success, runID: runID, act: .build, now: epoch.addingTimeInterval(1)
    )
    let alsoRunning = try journal.recordAttempt(cardID: cards[2], route: routeA, runID: runID, now: epoch)
    // No one holds the Act Lease any more: the request must still be written.
    _ = try journal.releaseActLease(runID: runID)

    let requested = try journal.requestOperatorAbortOfRunningAttempts(now: epoch.addingTimeInterval(2))

    #expect(requested == [running.id, alsoRunning.id])
    #expect(try journal.isOperatorAbortRequested(attemptID: running.id))
    #expect(try journal.isOperatorAbortRequested(attemptID: finished.id) == false)
    #expect(try journal.isOperatorAbortRequested(attemptID: stale.id) == false)
}
