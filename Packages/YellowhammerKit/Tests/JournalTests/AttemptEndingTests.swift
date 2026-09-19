import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// routing/exclude-tried-routes-on-retry (P7.7): the typed AttemptEnding vocabulary decides route
// exclusion — hard failure and rounds-exhausted are capability failures and exclude the Route;
// Crashed-Unknown never excludes ("a dying host is ours, not the model's"), and neither does a
// question, which also does not consume the Attempt. resetBudgetEpoch and the RouteRetried/
// BudgetEpochReset events are this story's other write path.

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

private let routeA = Route(cli: "claude", model: "opus", effort: "high")!
private let routeB = Route(cli: "codex", model: "gpt-5.4", effort: "medium")!

private func exclusionReason(
    _ journal: JournalStore, cardID: Int64, epoch budgetEpoch: Int, route: Route
) throws -> String? {
    try journal.read { db in
        try String.fetchOne(
            db,
            sql: """
            SELECT reason FROM route_exclusion
            WHERE card_id = ? AND budget_epoch = ? AND route_cli = ? AND route_model = ? AND route_effort = ?
            """,
            arguments: [cardID, budgetEpoch, route.cli, route.model, route.effort]
        )
    }
}

@Test("Hard failure by exit status excludes the Route with reason hard failure")
func hardFailureByExitStatusExcludes() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: .hardFailure(.exitStatus(2)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(10)
    )

    #expect(ended.result == "hard failure")
    #expect(ended.classification == "exit status 2")
    #expect(ended.consumedHow == "consumed; route excluded (hard failure)")
    #expect(try journal.excludedRoutes(cardID: cardID) == [routeA])
    #expect(try exclusionReason(journal, cardID: cardID, epoch: 0, route: routeA) == "hard failure")

    let events = try journal.events(ofType: .attemptEnded)
    #expect(events.count == 1)
    guard case .attemptEnded(let eventCardID, let issueID, let attemptID, let route, let outcome, let routeExcluded) =
        events[0].event
    else {
        Issue.record("expected attemptEnded")
        return
    }
    #expect(eventCardID == cardID)
    #expect(issueID == "ENG-1")
    #expect(attemptID == attempt.id)
    #expect(route == routeA)
    #expect(outcome == "hard failure")
    #expect(routeExcluded == true)
}

@Test("Hard failure reported by the pass's dual-key verdict excludes the Route")
func hardFailureReportedExcludes() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: .hardFailure(.reported(reason: "worker failed: bad diff")),
        runID: runID, act: .build, now: epoch.addingTimeInterval(10)
    )

    #expect(ended.classification == "reported: worker failed: bad diff")
    #expect(try journal.excludedRoutes(cardID: cardID) == [routeA])
}

@Test("Rounds-exhausted excludes the Route with reason rounds-exhausted")
func roundsExhaustedExcludes() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: .roundsExhausted(rounds: 3), runID: runID, act: .build,
        now: epoch.addingTimeInterval(10)
    )

    #expect(ended.result == "rounds-exhausted")
    #expect(ended.classification == "3 rounds")
    #expect(ended.consumedHow == "consumed; route excluded (rounds-exhausted)")
    #expect(try journal.excludedRoutes(cardID: cardID) == [routeA])
    #expect(try exclusionReason(journal, cardID: cardID, epoch: 0, route: routeA) == "rounds-exhausted")
}

@Test(
    "Crashed-Unknown, for any of its three causes, consumes the Attempt but never excludes the Route",
    arguments: [
        AttemptEnding.crashedUnknown(.resultFile(.empty)),
        AttemptEnding.crashedUnknown(.terminated(.aborted(forcedKill: false))),
        AttemptEnding.crashedUnknown(.signaled(9))
    ]
)
func crashedUnknownNeverExcludes(_ ending: AttemptEnding) throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: ending, runID: runID, act: .build, now: epoch.addingTimeInterval(10)
    )

    #expect(ended.result == "Crashed-Unknown")
    #expect(ended.consumedHow == "consumed; route not excluded (Crashed-Unknown)")
    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)

    let events = try journal.events(ofType: .attemptEnded)
    guard case .attemptEnded(_, _, _, _, _, let routeExcluded) = try #require(events.first?.event) else {
        Issue.record("expected attemptEnded")
        return
    }
    #expect(routeExcluded == false)
}

@Test("A question is not consumed and excludes nothing")
func questionDoesNotConsumeOrExclude() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: .question, runID: runID, act: .build, now: epoch.addingTimeInterval(10)
    )

    #expect(ended.result == "question")
    #expect(ended.classification == "asked a question")
    #expect(ended.consumedHow == "not consumed (asked a question)")
    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)

    let events = try journal.events(ofType: .attemptEnded)
    guard case .attemptEnded(_, _, _, _, _, let routeExcluded) = try #require(events.first?.event) else {
        Issue.record("expected attemptEnded")
        return
    }
    #expect(routeExcluded == false)
}

@Test("A cancellation is not consumed and excludes nothing")
func cancelledDoesNotConsumeOrExclude() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: .cancelled, runID: runID, act: .build, now: epoch.addingTimeInterval(10)
    )

    #expect(ended.result == "cancelled")
    #expect(ended.classification == "Card cancelled")
    #expect(ended.consumedHow == "not consumed (Card cancelled)")
    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)

    let events = try journal.events(ofType: .attemptEnded)
    guard case .attemptEnded(_, _, _, _, _, let routeExcluded) = try #require(events.first?.event) else {
        Issue.record("expected attemptEnded")
        return
    }
    #expect(routeExcluded == false)
}

@Test("Success is consumed and excludes nothing")
func successDoesNotExclude() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    let ended = try journal.endAttempt(
        attemptID: attempt.id, ending: .success, runID: runID, act: .build, now: epoch.addingTimeInterval(10)
    )

    #expect(ended.result == "success")
    #expect(ended.classification == "completed")
    #expect(ended.consumedHow == "consumed")
    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
}

@Test("Two hard failures on the same Route in one epoch leave one exclusion row, no error")
func repeatedHardFailureLeavesOneExclusionRow() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let attempt1 = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt1.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )
    let attempt2 = try journal.recordAttempt(
        cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(2)
    )
    _ = try journal.endAttempt(
        attemptID: attempt2.id, ending: .hardFailure(.exitStatus(2)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(3)
    )

    #expect(try journal.excludedRoutes(cardID: cardID) == [routeA])
    let count = try journal.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM route_exclusion WHERE card_id = ?", arguments: [cardID])
    }
    #expect(count == 1)
}

@Test("Ending an already-ended Attempt throws attemptEnded and writes no exclusion")
func endingEndedAttemptThrowsAndWritesNoExclusion() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .success, runID: runID, act: .build, now: epoch.addingTimeInterval(1)
    )

    #expect(throws: JournalError.attemptEnded(attemptID: attempt.id)) {
        try journal.endAttempt(
            attemptID: attempt.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
            now: epoch.addingTimeInterval(2)
        )
    }
    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
}

// resetBudgetEpoch, the Retry account, and the routeSource/overridePin round-trip are covered in
// BudgetEpochResetTests.swift, split out to keep this file under the length limit.
