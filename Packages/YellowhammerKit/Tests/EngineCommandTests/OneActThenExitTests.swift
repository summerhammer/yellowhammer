import Domain
@testable import Engine
import Foundation
import Journal
import Synchronization
import Testing

// shift-scheduling/do-one-acts-work-and-exit: the engine performs exactly one Act's work per
// invocation and exits, holding nothing in memory between Acts. A resumed Act reconstructs Attempt
// and Round counts, routes tried and Worktree paths entirely from the Journal.

/// A box for a value produced by an Act's work, read back after the invocation returns. Guarded
/// because the work runs in a different task than the test's assertions.
private final class ResultBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value?>

    init() { storage = Mutex(nil) }

    func set(_ value: Value) { storage.withLock { $0 = value } }
    var value: Value? { storage.withLock { $0 } }
}

private let route = Route(cli: "claude", model: "opus", effort: "high")!
private let nightStart = NightStart(rawValue: "2026-09-15")!

/// Inserts a fixture feature → cycle → card chain and returns their ids.
private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String = "main"
) throws -> (featureID: Int64, cardID: Int64) {
    let now = Date().formatted(.iso8601)
    return try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at) VALUES (?, ?, ?)",
            arguments: [issueID, "selected", now]
        )
        let featureID: Int64 = db.lastInsertedRowID

        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, now]
        )
        let cycleID: Int64 = db.lastInsertedRowID

        try db.execute(
            sql: """
            INSERT INTO card (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [cycleID, issueID, repository, "card", 1, CardState.todo.rawValue, 0, now]
        )
        return (featureID, db.lastInsertedRowID)
    }
}

/// Runs an invocation whose work records a Worktree, an Attempt and a Round, then signals `signal`
/// and sleeps far longer than the test will wait. The caller cancels the returned task once the
/// signal fires, so the invocation is killed mid-Act, exactly as a crashed process would be.
private func recordThenKillInvocation(
    journal: JournalStore,
    runID: RunID,
    featureID: Int64,
    cardID: Int64
) async throws -> Int64 {
    let attemptIDBox = ResultBox<Int64>()
    let (stream, continuation) = AsyncStream<Void>.makeStream()

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        runID: runID,
        work: { context in
            _ = try context.journal.recordWorktree(
                featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/wt-1",
                runID: context.runID
            )
            let attempt = try context.journal.recordAttempt(cardID: cardID, route: route, runID: context.runID)
            attemptIDBox.set(attempt.id)
            _ = try context.journal.recordRound(
                attemptID: attempt.id, lens: .review, verdict: "changes requested",
                requestedChanges: nil, judgedCommit: nil, runID: context.runID
            )
            continuation.yield(())
            try await Task.sleep(for: .seconds(60))
        }
    )

    let task = Task { try await invocation.run() }
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    return try #require(attemptIDBox.value)
}

@Test("A killed invocation leaves its Attempt, Round and Worktree in the Journal for the next invocation to rebuild")
func killedInvocationIsRebuiltFromTheJournal() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    let firstJournal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)
    let (featureID, cardID) = try insertFixtureCard(firstJournal, issueID: "CARD-1")
    let firstRunID = RunID()

    let attemptID = try await recordThenKillInvocation(
        journal: firstJournal, runID: firstRunID, featureID: featureID, cardID: cardID
    )

    let eventsAfterKill = try firstJournal.events()
    #expect(eventsAfterKill.map(\.type) == [.nightOpened, .actStarted, .actIncomplete])
    #expect(try firstJournal.currentActLease() == nil)

    // Invocation 2 shares nothing with invocation 1 but the row ids just inserted.
    let secondJournal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)
    let secondRunID = RunID()
    let historyBox = ResultBox<AttemptHistory>()
    let worktreesBox = ResultBox<[WorktreeRecord]>()

    let secondInvocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: secondJournal,
        runID: secondRunID,
        work: { context in
            historyBox.set(try context.journal.attemptHistory(cardID: cardID))
            worktreesBox.set(try context.journal.worktrees(featureID: featureID))
        }
    )
    try await secondInvocation.run()

    let history = try #require(historyBox.value)
    #expect(history.attemptCount == 1)
    #expect(history.roundCount == 1)
    #expect(history.routesTried == [route])
    #expect(history.openAttempt?.id == attemptID)

    let worktrees = try #require(worktreesBox.value)
    #expect(worktrees.count == 1)
    #expect(worktrees[0].path == "/tmp/wt-1")
    #expect(worktrees[0].isHeld)

    let eventsAfterSecondRun = try secondJournal.events()
    #expect(
        eventsAfterSecondRun.map(\.type) == [.nightOpened, .actStarted, .actIncomplete, .actStarted, .actEnded]
    )
}

@Test("A dead run's lease is reclaimed, and the open Attempt it left is visible to the next invocation")
func reclaimedRunsOpenAttemptIsVisible() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))

    let storeA = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)
    let (_, cardID) = try insertFixtureCard(storeA, issueID: "CARD-1")
    let runA = RunID()
    // Claimed eleven minutes ago and never heartbeated: a crashed, or long-asleep, run.
    let deadNow = Date().addingTimeInterval(-660)
    guard case .claimed = try storeA.claimActLease(act: .build, runID: runA, mode: .real, now: deadNow) else {
        Issue.record("The dead run did not claim the Act lease")
        return
    }
    let deadAttempt = try storeA.recordAttempt(cardID: cardID, route: route, runID: runA, now: deadNow)

    let secondJournal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)
    let secondRunID = RunID()
    let historyBox = ResultBox<AttemptHistory>()

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: secondJournal,
        runID: secondRunID,
        work: { context in
            historyBox.set(try context.journal.attemptHistory(cardID: cardID))
        }
    )
    try await invocation.run()

    let events = try secondJournal.events()
    #expect(events.map(\.type) == [.leaseReclaimed, .nightOpened, .actStarted, .actEnded])

    let history = try #require(historyBox.value)
    #expect(history.openAttempt?.id == deadAttempt.id)
}

@Test("run() leaves nothing resident: no heartbeat fires after it returns")
func runLeavesNothingResident() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)
    let shortPolicy = LeasePolicy(heartbeatInterval: 0.05, timeToLive: 2)

    let invocation = EngineInvocation(
        act: .build,
        mode: .real,
        nightStart: nightStart,
        journal: journal,
        leasePolicy: shortPolicy,
        work: { _ in try await Task.sleep(for: .milliseconds(200)) }
    )
    try await invocation.run()

    let eventCountAfterReturn = try journal.events().count
    let leaseAfterReturn = try journal.currentActLease()
    #expect(leaseAfterReturn == nil)

    try await Task.sleep(for: .milliseconds(500))

    #expect(try journal.events().count == eventCountAfterReturn)
    #expect(try journal.currentActLease() == nil)
}

@Test("The Act's work is handed the invocation's own runID, Act, mode and trigger")
func workReceivesTheInvocationsOwnContext() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let journal = try JournalStore.open(configurationDirectory: directory.url, projectID: projectID)
    let runID = RunID()
    let contextBox = ResultBox<ActContext>()

    let invocation = EngineInvocation(
        act: .land,
        mode: .rehearsal,
        nightStart: nightStart,
        journal: journal,
        trigger: .forced,
        runID: runID,
        work: { context in contextBox.set(context) }
    )
    try await invocation.run()

    let context = try #require(contextBox.value)
    #expect(context.act == .land)
    #expect(context.mode == .rehearsal)
    #expect(context.trigger == .forced)
    #expect(context.runID == runID)
}
