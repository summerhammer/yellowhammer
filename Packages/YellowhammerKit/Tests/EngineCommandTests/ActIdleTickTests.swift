import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-idle-\(UUID().uuidString)", directoryHint: .isDirectory)
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

// shift-scheduling/fire-an-act-on-schedule: every firing evaluates its own Act's trigger and exits
// quietly when it is not met, recording the no-op in that Project's Journal and writing nothing to
// the board. These cover the recording half — that the idle tick reaches the event log, and that
// every reason survives the round trip through it.

/// Inserts one Todo Card, which is enough to make the author trigger false.
private func insertTodoCard(_ journal: JournalStore, issueID: String) throws {
    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", JournalStore.timestamp(epoch)]
        )
        let featureID = db.lastInsertedRowID

        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(epoch)]
        )
        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                db.lastInsertedRowID, issueID, "main", "card", 1, CardState.todo.rawValue, 0,
                JournalStore.timestamp(epoch)
            ]
        )
    }
}

// MARK: - End-to-End Invocation Tests

@Test("false predicate makes EngineInvocation.run() return normally and records actIdle")
func invocationFalsePredicateReturnsNormally() async throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    // Create a scenario where the predicate is false (author with unfinished Cards)
    try insertTodoCard(journal, issueID: "CARD-1")

    let runID = RunID()
    let invocation = EngineInvocation(
        act: .author,
        mode: .real,
        journal: journal,
        trigger: .scheduled,
        runID: runID,
        leasePolicy: .ruled,
        work: { _ in
            Issue.record("Work should not be called")
        }
    )

    // Should return normally without throwing
    try await invocation.run()

    // Verify the event log contains actStarted, actIdle, actEnded
    let events = try journal.events()
    #expect(events.count == 3)
    #expect(events[0].event == .actStarted)
    #expect(events[0].act == .author)
    #expect(events[0].runID == runID)

    guard case .actIdle(let reason) = events[1].event else {
        Issue.record("Second event should be actIdle")
        return
    }
    #expect(reason == .unfinishedCardsPresent)
    #expect(events[1].act == .author)
    #expect(events[1].runID == runID)

    #expect(events[2].event == .actEnded)
    #expect(events[2].act == .author)
    #expect(events[2].runID == runID)

    // Verify the Act lease was released
    let leaseHeld = try journal.claimActLease(act: .author, runID: RunID(), mode: .real)
    if case .claimed = leaseHeld {
        // Success: lease was released
    } else {
        Issue.record("Act lease should have been released")
    }
}

// MARK: - Event Round-Trip Tests

@Test("actIdle event with unfinishedCardsPresent round-trips")
func actIdleUnfinishedCardsRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    try journal.append(.actIdle(reason: .unfinishedCardsPresent), act: .author, runID: runID, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .actIdle(let reason) = records[0].event else {
        Issue.record("Event is not actIdle")
        return
    }
    #expect(reason == .unfinishedCardsPresent)
}

@Test("actIdle event with noFeatureInFlight round-trips")
func actIdleNoFeatureRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    try journal.append(.actIdle(reason: .noFeatureInFlight), act: .build, runID: runID, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .actIdle(let reason) = records[0].event else {
        Issue.record("Event is not actIdle")
        return
    }
    #expect(reason == .noFeatureInFlight)
}

@Test("actIdle event with cycleHasNoUnfinishedCards round-trips")
func actIdleCycleNoUnfinishedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    try journal.append(.actIdle(reason: .cycleHasNoUnfinishedCards), act: .build, runID: runID, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .actIdle(let reason) = records[0].event else {
        Issue.record("Event is not actIdle")
        return
    }
    #expect(reason == .cycleHasNoUnfinishedCards)
}

@Test("actIdle event with cycleHasUnfinishedCards round-trips")
func actIdleCycleHasUnfinishedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()

    try journal.append(.actIdle(reason: .cycleHasUnfinishedCards), act: .land, runID: runID, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .actIdle(let reason) = records[0].event else {
        Issue.record("Event is not actIdle")
        return
    }
    #expect(reason == .cycleHasUnfinishedCards)
}
