import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The single Block Reason derivation (Attempt, Block and Reset Ruling 2026-09-19, OQ58):
// ``AttemptHistory/blockReason(inEpoch:)`` reads the epoch's last ENDED, consuming Attempt — a
// `question` ending is skipped, and so is any still-open Attempt.

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
private let routeA = Route(cli: "claude", model: "opus", effort: "high")!
private let routeB = Route(cli: "codex", model: "gpt-5.4", effort: "medium")!

private func insertFixtureCard(_ journal: JournalStore, budgetEpoch: Int = 0) throws -> Int64 {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: ["ENG-1", "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        let cycleID = db.lastInsertedRowID
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                cycleID, "ENG-1", "backend", "impl", 1, CardState.todo.rawValue, budgetEpoch,
                JournalStore.timestamp(epoch)
            ]
        )
        return db.lastInsertedRowID
    }
}

private func claimLease(_ journal: JournalStore, runID: RunID, now: Date = epoch) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: now) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

@Test("No such Attempt: nothing ever dispatched blocks hard failure")
func noAttemptBlocksHardFailure() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hardFailure)
}

@Test("A hard failure final Attempt blocks hard failure")
func hardFailureFinalBlocksHardFailure() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hardFailure)
}

@Test("A Crashed-Unknown final Attempt blocks host crash")
func crashedUnknownFinalBlocksHostCrash() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .crashedUnknown(.signaled(9)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hostCrash)
}

@Test("A rounds-exhausted final Attempt blocks by its last Round's Lens")
func roundsExhaustedFinalBlocksByLens() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.recordRound(
        attemptID: attempt.id, lens: .check, verdict: "failed", requestedChanges: nil, judgedCommit: nil,
        runID: runID, now: epoch.addingTimeInterval(1)
    )
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .roundsExhausted(rounds: 1), runID: runID, act: .build,
        now: epoch.addingTimeInterval(2)
    )

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .blockedByCheck)
}

@Test("Mixed history: hard failure then a final Crashed-Unknown blocks host crash")
func hardFailureThenCrashedUnknownBlocksHostCrash() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: first.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )
    let second = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(2)
    )
    _ = try journal.endAttempt(
        attemptID: second.id, ending: .crashedUnknown(.signaled(9)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(3)
    )

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hostCrash)
}

@Test("Mixed history: Crashed-Unknown then a final hard failure blocks hard failure")
func crashedUnknownThenHardFailureBlocksHardFailure() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: first.id, ending: .crashedUnknown(.signaled(9)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )
    let second = try journal.recordAttempt(
        cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(2)
    )
    _ = try journal.endAttempt(
        attemptID: second.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(3)
    )

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hardFailure)
}

@Test("A question ending is skipped: the derivation reads the prior consuming Attempt instead")
func questionEndingIsSkipped() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: first.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )
    let second = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(2)
    )
    _ = try journal.endAttempt(
        attemptID: second.id, ending: .question, runID: runID, act: .build, now: epoch.addingTimeInterval(3)
    )

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hardFailure)
}

@Test("An open Attempt is skipped: the derivation reads the prior ended Attempt instead")
func openAttemptIsSkipped() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: first.id, ending: .crashedUnknown(.signaled(9)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )
    _ = try journal.recordAttempt(cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(2))

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.blockReason(inEpoch: 0) == .hostCrash)
}
