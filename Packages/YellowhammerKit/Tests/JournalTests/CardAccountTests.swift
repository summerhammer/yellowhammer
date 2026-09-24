import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

// The app's read behind a Card (roadmap P14.5): "Opening a Journal in the app while an Act writes it
// causes no write conflict and no modification." These tests exercise `cardAccount(issueID:)` through
// a store opened exactly as the app opens one, `openReadOnly`, concurrently with a writer.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private let routeA = Route(cli: "claude", model: "opus", effort: "high")!
private let routeB = Route(cli: "codex", model: "gpt-5", effort: "medium")!

/// Inserts a fixture feature → cycle → card chain and returns the Card's id.
private func insertFixtureCard(
    _ journal: JournalStore,
    issueID: String,
    repository: String,
    budgetEpoch: Int = 0
) throws -> Int64 {
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
            VALUES (?, ?, ?, 'card', 1, ?, ?, ?)
            """,
            arguments: [
                cycleID, issueID, repository, CardState.todo.rawValue, budgetEpoch, JournalStore.timestamp(epoch)
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

/// The two Attempts ``seedTwoAttemptCard(_:)`` records against CARD-1.
private struct SeededAttempts {
    let cardID: Int64
    let first: AttemptRecord
    let second: AttemptRecord
}

/// Seeds CARD-1 with two Attempts (a failed check Round + checkRan on Route A, an approved review
/// Round + two checkRan events on Route B) and CARD-2 with one Attempt and its own checkRan event, so
/// tests can assert CARD-1's account excludes CARD-2's events.
private func seedTwoAttemptCard(_ journal: JournalStore) throws -> SeededAttempts {
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let otherCardID = try insertFixtureCard(journal, issueID: "CARD-2", repository: "main")

    let runID = RunID()
    try claimLease(journal, runID: runID)

    let first = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    _ = try journal.recordRound(
        attemptID: first.id, lens: .check, verdict: "failed", requestedChanges: "fix build",
        judgedCommit: "abc123", runID: runID, now: epoch.addingTimeInterval(10)
    )
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: "CARD-1", attemptID: first.id, result: .failed,
            exitStatus: 1, output: "build failed: line 42"
        ),
        runID: runID, now: epoch.addingTimeInterval(11)
    )
    _ = try journal.endAttempt(
        attemptID: first.id, result: "roundsExhausted", runID: runID, now: epoch.addingTimeInterval(20)
    )

    let second = try journal.recordAttempt(
        cardID: cardID, route: routeB, runID: runID, now: epoch.addingTimeInterval(30)
    )
    _ = try journal.recordRound(
        attemptID: second.id, lens: .review, verdict: "approved", requestedChanges: nil,
        judgedCommit: "def456", runID: runID, now: epoch.addingTimeInterval(40)
    )
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: "CARD-1", attemptID: second.id, result: .passed, exitStatus: 0, output: nil
        ),
        runID: runID, now: epoch.addingTimeInterval(41)
    )
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: "CARD-1", attemptID: second.id, result: .declaredNone,
            exitStatus: nil, output: nil
        ),
        runID: runID, now: epoch.addingTimeInterval(42)
    )

    // Another Card's checkRan event must not leak into CARD-1's account.
    let otherAttempt = try journal.recordAttempt(cardID: otherCardID, route: routeA, runID: runID, now: epoch)
    try journal.append(
        .checkRan(
            cardID: otherCardID, issueID: "CARD-2", attemptID: otherAttempt.id, result: .passed,
            exitStatus: 0, output: nil
        ),
        runID: runID, now: epoch.addingTimeInterval(50)
    )

    return SeededAttempts(cardID: cardID, first: first, second: second)
}

@Test(
    """
    cardAccount reads the Card, two Attempts across two Routes, their Rounds, and every checkRan \
    event for the Card, excludes another Card's events, and returns nil for an unknown issue id
    """
)
func cardAccountReadsFullSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectID = try #require(ProjectID(rawValue: "fixture"))

    let journal = try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    let seeded = try seedTwoAttemptCard(journal)
    let (first, second) = (seeded.first, seeded.second)

    let readOnly = try JournalStore.openReadOnly(at: journal.fileURL, projectID: projectID)

    let account = try #require(try readOnly.cardAccount(issueID: "CARD-1"))
    #expect(account.card.issueID == "CARD-1")
    #expect(account.history.attemptCount == 2)
    #expect(account.history.attempts.map(\.route) == [routeA, routeB])
    #expect(account.history.attempts[0].rounds.map(\.lens) == [.check])
    #expect(account.history.attempts[1].rounds.map(\.lens) == [.review])

    #expect(account.checkRuns.count == 3)
    #expect(account.checkRuns.map(\.result) == [.failed, .passed, .declaredNone])
    #expect(account.checkRuns.allSatisfy { $0.attemptID == first.id || $0.attemptID == second.id })

    let failedRun = try #require(account.checkRuns.first { $0.result == .failed })
    #expect(failedRun.exitStatus == 1)
    #expect(failedRun.output == "build failed: line 42")
    #expect(failedRun.attemptID == first.id)

    #expect(account.checkRuns(attemptID: first.id).map(\.result) == [.failed])
    #expect(account.checkRuns(attemptID: second.id).map(\.result) == [.passed, .declaredNone])

    let unknown = try readOnly.cardAccount(issueID: "NOT-A-CARD")
    #expect(unknown == nil)
}

@Test(
    """
    While another process writes the Journal, a read-only openReadOnly store's cardAccount calls never \
    throw and never see a count go backwards, and every one of the writer's transactions commits
    """
)
func readingWhileAnotherProcessWritesCausesNoConflict() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectID = try #require(ProjectID(rawValue: "fixture"))

    // Seed through the engine's own open, then let that connection go: the Act that writes next is
    // another process, as it always is for the app — `yh` never shares the app's process.
    let fileURL = try seedOneCheckRun(directory: directory, projectID: projectID)

    // The writer: `sqlite3` committing one `checkRan` row per write transaction, copied from the seeded
    // one, exactly as SQLite's own locking sees an Act — a separate process on the same file.
    let transactionCount = 200
    let writer = Process()
    writer.executableURL = URL(filePath: "/usr/bin/sqlite3")
    writer.arguments = ["-bail", "-cmd", ".timeout 5000", fileURL.path(percentEncoded: false)]
    let script = Pipe()
    let errors = Pipe()
    writer.standardInput = script
    writer.standardError = errors
    writer.standardOutput = FileHandle.nullDevice

    let readOnly = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
    try writer.run()
    let transaction = """
        BEGIN IMMEDIATE;
        INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
        SELECT night_id, act, run_id, type, occurred_at, payload FROM event WHERE id = (SELECT MIN(id) FROM event);
        COMMIT;

        """
    script.fileHandleForWriting.write(Data(String(repeating: transaction, count: transactionCount).utf8))
    try script.fileHandleForWriting.close()

    var reads = 0
    var lastCount = 0
    while writer.isRunning || reads < 50 {
        let account = try #require(try readOnly.cardAccount(issueID: "CARD-1"))
        #expect(account.checkRuns.count >= lastCount)
        lastCount = account.checkRuns.count
        reads += 1
    }
    writer.waitUntilExit()

    let stderr = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(writer.terminationStatus == 0, "sqlite3: \(stderr)")
    let finalAccount = try #require(try readOnly.cardAccount(issueID: "CARD-1"))
    #expect(finalAccount.checkRuns.count == 1 + transactionCount)
}

@Test(
    """
    A read-only open plus cardAccount calls leave the Journal file byte-for-byte identical, create \
    no new -journal/-wal sibling, and a write attempted through the read-only store throws
    """
)
func readOnlyOpenAndReadsDoNotModifyTheFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let projectID = try #require(ProjectID(rawValue: "fixture"))

    let journal = try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: "CARD-1", attemptID: attempt.id, result: .passed, exitStatus: 0, output: nil
        ),
        runID: runID, now: epoch.addingTimeInterval(1)
    )

    let fileURL = journal.fileURL
    let siblingsBefore = try siblingFiles(of: fileURL)
    let bytesBefore = try Data(contentsOf: fileURL)

    let readOnly = try JournalStore.openReadOnly(at: fileURL, projectID: projectID)
    for _ in 0..<10 {
        _ = try readOnly.cardAccount(issueID: "CARD-1")
    }

    let bytesAfter = try Data(contentsOf: fileURL)
    #expect(bytesBefore == bytesAfter)

    let siblingsAfter = try siblingFiles(of: fileURL)
    #expect(siblingsAfter.subtracting(siblingsBefore).isEmpty)

    var writeThrew = false
    do {
        try readOnly.write { db in
            try db.execute(sql: "INSERT INTO event (type, occurred_at) VALUES ('card-cancelled', ?)", arguments: [
                JournalStore.timestamp(epoch)
            ])
        }
    } catch {
        writeThrew = true
    }
    #expect(writeThrew)
}

/// A Journal under `directory` holding CARD-1 with one open Attempt and one `checkRan` event; returns
/// its file once the engine's connection to it is gone.
private func seedOneCheckRun(directory: URL, projectID: ProjectID) throws -> URL {
    let journal = try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    let cardID = try insertFixtureCard(journal, issueID: "CARD-1", repository: "main")
    let runID = RunID()
    try claimLease(journal, runID: runID)
    let attempt = try journal.recordAttempt(cardID: cardID, route: routeA, runID: runID, now: epoch)
    try journal.append(
        .checkRan(
            cardID: cardID, issueID: "CARD-1", attemptID: attempt.id, result: .passed, exitStatus: 0, output: nil
        ),
        runID: runID, now: epoch
    )
    return journal.fileURL
}

/// The names of every file in `url`'s directory whose name starts with `url`'s own name — i.e. the
/// database file itself plus any `-journal`/`-wal`/`-shm` sibling SQLite may create beside it.
private func siblingFiles(of url: URL) throws -> Set<String> {
    let directory = url.deletingLastPathComponent()
    let baseName = url.lastPathComponent
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return Set(names.filter { $0.hasPrefix(baseName) })
}
