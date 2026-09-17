import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// routing/exclude-tried-routes-on-retry (P7.7): resetBudgetEpoch, the retry account it resets, and the
// provenance fields recordAttempt writes. Split out of AttemptEndingTests.swift to keep that file under
// the length limit.

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

private struct RouteRetriedFields {
    let attemptID: Int64
    let route: Route
    let differentRoute: Bool
}

private func routeRetried(_ record: JournalEventRecord) -> RouteRetriedFields? {
    guard case .routeRetried(_, _, let attemptID, let route, let differentRoute) = record.event else { return nil }
    return RouteRetriedFields(attemptID: attemptID, route: route, differentRoute: differentRoute)
}

@Test("resetBudgetEpoch bumps the epoch and clears current exclusions; refused with an open Attempt")
func resetBudgetEpochBehavior() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.endAttempt(
        attemptID: attempt.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(10)
    )
    #expect(try journal.excludedRoutes(cardID: cardID) == [routeA])

    let reset = try journal.resetBudgetEpoch(
        cardID: cardID, reason: "Override `claude/-/-` pinned in triage", runID: runID, act: .build,
        nightID: nil, now: epoch.addingTimeInterval(20)
    )

    #expect(reset.budgetEpoch == 1)
    #expect(try journal.card(id: cardID).budgetEpoch == 1)
    #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
    #expect(try journal.attemptHistory(cardID: cardID).excludedRoutes == [routeA])

    let events = try journal.events(ofType: .budgetEpochReset)
    #expect(events.count == 1)
    #expect(
        events[0].event == .budgetEpochReset(
            cardID: cardID, issueID: "ENG-1", from: 0, to: 1, reason: "Override `claude/-/-` pinned in triage"
        )
    )

    let second = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(30)
    )
    #expect(throws: JournalError.attemptStillOpen(cardID: cardID, attemptID: second.id)) {
        try journal.resetBudgetEpoch(
            cardID: cardID, reason: "x", runID: runID, act: .build, nightID: nil, now: epoch.addingTimeInterval(40)
        )
    }
}

@Test("Retry records track whether a later Attempt in the same epoch lands on an already-tried Route")
func retryRecordsTrackDifferentRoute() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let attempt1 = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    #expect(try journal.events(ofType: .routeRetried).isEmpty)
    _ = try journal.endAttempt(
        attemptID: attempt1.id, ending: .hardFailure(.exitStatus(1)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(1)
    )

    let attempt2 = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(2)
    )
    var retryEvents = try journal.events(ofType: .routeRetried)
    #expect(retryEvents.count == 1)
    let retry2 = try #require(routeRetried(retryEvents[0]))
    #expect(retry2.attemptID == attempt2.id)
    #expect(retry2.route == routeB)
    #expect(retry2.differentRoute == true)
    _ = try journal.endAttempt(
        attemptID: attempt2.id, ending: .crashedUnknown(.signaled(9)), runID: runID, act: .build,
        now: epoch.addingTimeInterval(3)
    )

    let attempt3 = try journal.recordAttempt(
        cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(4)
    )
    retryEvents = try journal.events(ofType: .routeRetried)
    #expect(retryEvents.count == 2)
    let retry3 = try #require(routeRetried(retryEvents[1]))
    #expect(retry3.attemptID == attempt3.id)
    #expect(retry3.route == routeA)
    #expect(retry3.differentRoute == false)
    _ = try journal.endAttempt(
        attemptID: attempt3.id, ending: .success, runID: runID, act: .build, now: epoch.addingTimeInterval(5)
    )

    _ = try journal.resetBudgetEpoch(
        cardID: cardID, reason: "test", runID: runID, act: .build, nightID: nil, now: epoch.addingTimeInterval(6)
    )
    _ = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch.addingTimeInterval(7))
    #expect(try journal.events(ofType: .routeRetried).count == 2)

    let history = try journal.attemptHistory(cardID: cardID)
    #expect(
        history.retries == [
            AttemptHistory.Retry(attemptID: attempt2.id, route: routeB, differentRoute: true),
            AttemptHistory.Retry(attemptID: attempt3.id, route: routeA, differentRoute: false)
        ]
    )
}

@Test("overridePin and routeSource round-trip through recordAttempt")
func overridePinAndRouteSourceRoundTrip() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let cardID = try insertFixtureCard(journal)
    let runID = RunID()
    try claimLease(journal, runID: runID)

    let attempt = try journal.recordAttempt(
        cardID: cardID, route: routeA, routeSource: "fallback:1", override: Override(cli: "claude"),
        runID: runID, now: epoch
    )

    #expect(attempt.routeSource == "fallback:1")
    #expect(attempt.overridePin == "claude/-/-")

    let history = try journal.attemptHistory(cardID: cardID)
    #expect(history.attempts[0].routeSource == "fallback:1")
    #expect(history.attempts[0].overridePin == "claude/-/-")
}
