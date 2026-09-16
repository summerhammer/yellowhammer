import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// shift-scheduling/do-one-acts-work-and-exit: an invocation holds nothing in memory between Acts.
// A resumed Act reconstructs Attempt and Round counts, routes tried and Worktree paths entirely from
// the Journal, so the Attempt and Round rows are the whole of that state.

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

/// Inserts a fixture feature → cycle → card chain and returns their ids.
private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String,
    authoredOrder: Int = 1,
    budgetEpoch: Int = 0
) throws -> (featureID: Int64, cardID: Int64) {
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
                cycleID, issueID, repository, "card", authoredOrder, CardState.todo.rawValue, budgetEpoch,
                JournalStore.timestamp(epoch)
            ]
        )
        return (featureID, db.lastInsertedRowID)
    }
}

/// Claims the Act-scoped lease for `runID`, so writes under it revalidate.
private func claimLease(_ journal: JournalStore, runID: RunID, now: Date = epoch) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .real, now: now) else {
        Issue.record("Could not claim the Act lease")
        return
    }
}

private let routeA = Route(cli: "claude", model: "opus", effort: "high")!
private let routeB = Route(cli: "codex", model: "gpt-5", effort: "medium")!

@Test("A fresh Card has no Attempts, no Rounds, no Routes tried, no open Attempt, no exclusions")
func freshCardHasEmptyHistory() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")

    let history = try journal.attemptHistory(cardID: cardID)

    #expect(history.attemptCount == 0)
    #expect(history.roundCount == 0)
    #expect(history.routesTried.isEmpty)
    #expect(history.openAttempt == nil)
    #expect(history.excludedRoutes.isEmpty)
}

@Test("recordAttempt without a held lease throws actLeaseLost")
func recordAttemptWithoutLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    }
}

@Test("recordRound without a held lease throws actLeaseLost")
func recordRoundWithoutLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.releaseActLease(runID: runID)

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.recordRound(
            attemptID: attempt.id, lens: .review, verdict: "changes", requestedChanges: nil,
            judgedCommit: nil, runID: runID, now: epoch
        )
    }
}

@Test("endAttempt without a held lease throws actLeaseLost")
func endAttemptWithoutLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.releaseActLease(runID: runID)

    #expect(throws: JournalError.actLeaseLost(runID: runID, holder: nil)) {
        try journal.endAttempt(attemptID: attempt.id, result: "landed", runID: runID, now: epoch)
    }
}

@Test("A different run's held lease also blocks every write with actLeaseLost")
func recordAttemptUnderAnotherRunsLeaseThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let holder = RunID()
    let other = RunID()
    try claimLease(journal, runID: holder)

    let holderLease = try journal.currentActLease()
    #expect(throws: JournalError.actLeaseLost(runID: other, holder: holderLease)) {
        try journal.recordAttempt(cardID: cardID, route: routeA, runID: other, now: epoch)
    }
}

@Test("One Attempt with a review Round and a check Round reads back field-for-field")
func oneAttemptTwoRoundsReadBack() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main", budgetEpoch: 2)
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    #expect(attempt.budgetEpoch == 2)
    #expect(attempt.startedAt == JournalStore.stored(epoch))
    #expect(attempt.route == routeA)
    #expect(attempt.isOpen)

    let reviewRound = try journal.recordRound(
        attemptID: attempt.id, lens: .review, verdict: "changes requested",
        requestedChanges: "fix the thing", judgedCommit: "abc123",
        runID: runID, now: epoch.addingTimeInterval(60)
    )
    let checkRound = try journal.recordRound(
        attemptID: attempt.id, lens: .check, verdict: "failed",
        requestedChanges: nil, judgedCommit: "def456",
        runID: runID, now: epoch.addingTimeInterval(120)
    )

    #expect(reviewRound.lens == .review)
    #expect(reviewRound.verdict == "changes requested")
    #expect(reviewRound.requestedChanges == "fix the thing")
    #expect(reviewRound.judgedCommit == "abc123")
    #expect(reviewRound.createdAt == JournalStore.stored(epoch.addingTimeInterval(60)))

    #expect(checkRound.lens == .check)
    #expect(checkRound.judgedCommit == "def456")
    #expect(checkRound.requestedChanges == nil)

    let history = try journal.attemptHistory(cardID: cardID)
    #expect(history.attemptCount == 1)
    #expect(history.roundCount == 2)
    #expect(history.attempts[0].rounds.map(\.id) == [reviewRound.id, checkRound.id])
    #expect(history.attempts[0].rounds[0] == reviewRound)
    #expect(history.attempts[0].rounds[1] == checkRound)
}

@Test("Ending an Attempt, then a second Attempt on a different Route, then a third on the first Route again")
func threeAttemptsAcrossTwoRoutes() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    let ended = try journal.endAttempt(
        attemptID: first.id, result: "diverged", classification: "some-classification",
        consumedHow: "expired", runID: runID, now: epoch.addingTimeInterval(10)
    )
    #expect(!ended.isOpen)
    #expect(ended.result == "diverged")
    #expect(ended.classification == "some-classification")
    #expect(ended.consumedHow == "expired")
    #expect(ended.endedAt == JournalStore.stored(epoch.addingTimeInterval(10)))

    let second = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(20)
    )
    _ = try journal.endAttempt(
        attemptID: second.id, result: "diverged", runID: runID, now: epoch.addingTimeInterval(30)
    )

    let third = try journal.recordAttempt(
        cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(40)
    )

    let history = try journal.attemptHistory(cardID: cardID)
    #expect(history.attemptCount == 3)
    #expect(history.routesTried == [routeA, routeB])
    #expect(history.openAttempt?.id == third.id)
}

@Test("A second Attempt while one is open throws attemptStillOpen")
func secondAttemptWhileOpenThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)

    #expect(throws: JournalError.attemptStillOpen(cardID: cardID, attemptID: first.id)) {
        try journal.recordAttempt(cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(1))
    }
}

@Test("A Round on an ended Attempt throws attemptEnded")
func roundOnEndedAttemptThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(attemptID: attempt.id, result: "landed", runID: runID, now: epoch.addingTimeInterval(1))

    #expect(throws: JournalError.attemptEnded(attemptID: attempt.id)) {
        try journal.recordRound(
            attemptID: attempt.id, lens: .review, verdict: "changes", requestedChanges: nil,
            judgedCommit: nil, runID: runID, now: epoch.addingTimeInterval(2)
        )
    }
}

@Test("Ending an already-ended Attempt throws attemptEnded")
func endingEndedAttemptThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(attemptID: attempt.id, result: "landed", runID: runID, now: epoch.addingTimeInterval(1))

    #expect(throws: JournalError.attemptEnded(attemptID: attempt.id)) {
        try journal.endAttempt(attemptID: attempt.id, result: "landed", runID: runID, now: epoch.addingTimeInterval(2))
    }
}

@Test("An unknown Attempt id throws attemptUnknown for both recordRound and endAttempt")
func unknownAttemptThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    try claimLease(journal, runID: runID)

    #expect(throws: JournalError.attemptUnknown(attemptID: 999)) {
        try journal.recordRound(
            attemptID: 999, lens: .review, verdict: "changes", requestedChanges: nil,
            judgedCommit: nil, runID: runID, now: epoch
        )
    }
    #expect(throws: JournalError.attemptUnknown(attemptID: 999)) {
        try journal.endAttempt(attemptID: 999, result: "landed", runID: runID, now: epoch)
    }
}

@Test("An unknown Card id throws cardUnknown for recordAttempt and attemptHistory")
func unknownCardThrows() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    try claimLease(journal, runID: runID)

    #expect(throws: JournalError.cardUnknown(cardID: 999)) {
        try journal.recordAttempt(cardID: 999, route: routeA, runID: runID, now: epoch)
    }
    #expect(throws: JournalError.cardUnknown(cardID: 999)) {
        try journal.attemptHistory(cardID: 999)
    }
}

@Test("route_exclusion rows read back as excludedRoutes, ordered by excluded_at then Route")
func excludedRoutesReadBack() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let (_, cardID) = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")

    let insertSQL = """
        INSERT INTO route_exclusion (card_id, budget_epoch, route_cli, route_model, route_effort, reason, excluded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
    try journal.write { db in
        try db.execute(
            sql: insertSQL,
            arguments: [cardID, 0, routeB.cli, routeB.model, routeB.effort, "budget", JournalStore.timestamp(epoch)]
        )
        try db.execute(
            sql: insertSQL,
            arguments: [
                cardID, 0, routeA.cli, routeA.model, routeA.effort, "divergence",
                JournalStore.timestamp(epoch.addingTimeInterval(10))
            ]
        )
    }

    let history = try journal.attemptHistory(cardID: cardID)
    #expect(history.excludedRoutes == [routeB, routeA])
}
