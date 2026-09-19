import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The Attempt budget guard's single source of consumption counting (roadmap P8.7):
// ``AttemptHistory/consumption(inEpoch:)`` reads mixed endings, scopes to one budget epoch, counts an
// open (unclassified) Attempt as consumed, and a question as not.

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

@Test("Mixed endings in one epoch: every kind but a question is consumed, and each is counted by its own kind")
func mixedEndingsAreCountedByKind() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)

    func attempt(_ ending: AttemptEnding?, at offset: TimeInterval) throws -> AttemptRecord {
        let recorded = try journal.recordAttempt(
            cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(offset)
        )
        if let ending {
            _ = try journal.endAttempt(
                attemptID: recorded.id, ending: ending, runID: runID, act: .build,
                now: epoch.addingTimeInterval(offset + 1)
            )
        }
        return recorded
    }

    _ = try attempt(.hardFailure(.exitStatus(1)), at: 0)
    _ = try attempt(.crashedUnknown(.signaled(9)), at: 10)
    _ = try attempt(.roundsExhausted(rounds: 2), at: 20)
    _ = try attempt(.question, at: 30)
    _ = try attempt(.success, at: 40)

    let history = try journal.attemptHistory(cardID: cardID)
    let consumption = history.consumption(inEpoch: 0)

    #expect(consumption.consumed == 4)
    #expect(consumption.routesFailed == 1)
    #expect(consumption.crashedUnknown == 1)
    #expect(consumption.roundsExhausted == 1)
    #expect(consumption.succeeded == 1)
    #expect(consumption.notConsumed == 1)
    #expect(consumption.description == [
        "4 Attempts consumed: 1 Route failed, 1 round budget exhausted, 1 Crashed-Unknown, 1 succeeded"
    ].joined())
}

@Test("An open Attempt (no result yet) counts as consumed: the row is written at dispatch")
func openAttemptCountsAsConsumed() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    _ = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let consumption = try journal.attemptHistory(cardID: cardID).consumption(inEpoch: 0)

    #expect(consumption.consumed == 1)
    #expect(consumption.description == "1 Attempt consumed")
}

@Test("A question consumes nothing and is not counted in the description's parts")
func questionAloneDoesNotConsume() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .question, runID: runID, act: .build, now: epoch.addingTimeInterval(1)
    )

    let consumption = try journal.attemptHistory(cardID: cardID).consumption(inEpoch: 0)

    #expect(consumption.consumed == 0)
    #expect(consumption.notConsumed == 1)
    #expect(consumption.description == "0 Attempts consumed")
}

@Test("consumption(inEpoch:) scopes to one budget epoch: an earlier epoch's Attempts do not count")
func consumptionScopesToOneEpoch() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let earlier = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: earlier.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )
    _ = try journal.resetBudgetEpoch(
        cardID: cardID, reason: "Override pinned in triage", runID: runID, act: .build, nightID: nil,
        now: epoch.addingTimeInterval(2)
    )
    let afterReset = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(3)
    )
    _ = try journal.endAttempt(
        attemptID: afterReset.id, ending: .success, runID: runID, act: .build, now: epoch.addingTimeInterval(4)
    )

    let history = try journal.attemptHistory(cardID: cardID)
    let oldEpoch = history.consumption(inEpoch: 0)
    let newEpoch = history.consumption(inEpoch: 1)

    #expect(oldEpoch.consumed == 1)
    #expect(oldEpoch.routesFailed == 1)
    #expect(oldEpoch.succeeded == 0)
    #expect(newEpoch.consumed == 1)
    #expect(newEpoch.succeeded == 1)
    #expect(newEpoch.routesFailed == 0)
}
