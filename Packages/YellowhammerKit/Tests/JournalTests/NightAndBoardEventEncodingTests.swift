import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

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

@Test("nightClosed event with its reason round-trips", arguments: NightCloseReason.allCases)
func nightClosedRoundTrips(_ reason: NightCloseReason) throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    _ = try journal.append(.nightClosed(reason: reason), act: .land, runID: RunID(), nightID: nil, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].event == .nightClosed(reason: reason))
    #expect(records[0].act == .land)
}

@Test("nightOpenedAndDied event names the dead Night by id and night_start")
func nightOpenedAndDiedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let dead = try #require(NightStart(rawValue: "2026-09-14"))

    _ = try journal.append(.nightOpenedAndDied(nightID: 7, nightStart: dead), act: .author, runID: RunID(), now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].event == .nightOpenedAndDied(nightID: 7, nightStart: dead))
    let payload = try journal.read { try String.fetchOne($0, sql: "SELECT payload FROM event WHERE id = 1") }
    #expect(payload == #"{"night_id":"7","night_start":"2026-09-14"}"#)
}

@Test("A NightClosed event with a reason outside the closed set is unreadable")
func nightClosedWithUnknownReasonIsUnreadable() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    try journal.write { db in
        try db.execute(
            sql: "INSERT INTO event (type, occurred_at, payload) VALUES (?, ?, ?)",
            arguments: ["NightClosed", JournalStore.timestamp(epoch), #"{"reason":"lunch"}"#]
        )
    }

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        try journal.events()
    }
}

@Test("managedBlockWritten event round-trips with prose and rendered hashes")
func managedBlockWrittenRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let proseHash = "sha256_prose"
    let renderedHash = "sha256_rendered"

    _ = try journal.append(
        .managedBlockWritten(
            issueID: "ISSUE-1",
            preservedProseHash: proseHash,
            renderedHash: renderedHash
        ),
        act: .author,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .managedBlockWritten(let readIssueID, let readProseHash, let readRenderedHash) =
        records[0].event
    else {
        Issue.record("Event is not managedBlockWritten")
        return
    }
    #expect(readIssueID == "ISSUE-1")
    #expect(readProseHash == proseHash)
    #expect(readRenderedHash == renderedHash)
}

// nightCardOpened and nightCardCompleted round-trips are covered in NightCardJournalTests.swift,
// split out to keep this file under the length limit.

@Test("boardWriteFailed event round-trips with required fields and optional issueID")
func boardWriteFailedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let clientID = UUID()

    _ = try journal.append(
        .boardWriteFailed(
            clientID: clientID,
            operation: "create_comment",
            issueID: "ISSUE-1",
            reason: "rate limited"
        ),
        act: .build,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .boardWriteFailed(let readClientID, let readOp, let readIssueID, let readReason) =
        records[0].event
    else {
        Issue.record("Event is not boardWriteFailed")
        return
    }
    #expect(readClientID == clientID)
    #expect(readOp == "create_comment")
    #expect(readIssueID == "ISSUE-1")
    #expect(readReason == "rate limited")
}

@Test("boardWriteFailed without issueID omits the key and round-trips")
func boardWriteFailedWithoutIssueIDRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let clientID = UUID()

    _ = try journal.append(
        .boardWriteFailed(
            clientID: clientID,
            operation: "delete_comment",
            issueID: nil,
            reason: "not found"
        ),
        act: .build,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .boardWriteFailed(let readClientID, let readOp, let readIssueID, let readReason) =
        records[0].event
    else {
        Issue.record("Event is not boardWriteFailed")
        return
    }
    #expect(readClientID == clientID)
    #expect(readOp == "delete_comment")
    #expect(readIssueID == nil)
    #expect(readReason == "not found")

    // Verify the payload doesn't include issue_id key
    let payload = try journal.read {
        try String.fetchOne($0, sql: "SELECT payload FROM event WHERE id = 1")
    }
    #expect(payload?.contains("issue_id") == false)
}

// The five reconciliation events (WorktreeLost, WorktreeFenced, WorktreeNotQuiescent,
// WorktreeWIPCommitted, WorktreeReconciliationFailed) round-trip in WorktreeEventEncodingTests.swift,
// split out to keep this file under the length limit.

@Test("outboxGroupRolledBack event round-trips with group_id and reason")
func outboxGroupRolledBackRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.append(
        .outboxGroupRolledBack(groupID: "group-1", reason: "insufficient budget"),
        act: .land,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .outboxGroupRolledBack(let readGroupID, let readReason) = records[0].event else {
        Issue.record("Event is not outboxGroupRolledBack")
        return
    }
    #expect(readGroupID == "group-1")
    #expect(readReason == "insufficient budget")
}

@Test("routeExhausted event round-trips")
func routeExhaustedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let reason = "fallbacks exhausted for the Routing Entry (kind `impl`, any Repo Role): `claude/opus/high` excluded"

    let event = JournalEvent.routeExhausted(cardID: 7, issueID: "ENG-7", reason: reason)
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .routeExhausted)

    #expect(records.count == 1)
    #expect(records[0].event == .routeExhausted(cardID: 7, issueID: "ENG-7", reason: reason))
}

@Test("overrideRefused event round-trips")
func overrideRefusedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let reason = "Override `codex/gpt-5.4/medium` pins `codex`, which is not offered by its Probe: never probed"

    let event = JournalEvent.overrideRefused(cardID: 7, issueID: "ENG-7", reason: reason)
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events(ofType: .overrideRefused)

    #expect(records.count == 1)
    #expect(records[0].event == .overrideRefused(cardID: 7, issueID: "ENG-7", reason: reason))
}

// attemptEnded, routeRetried, budgetEpochReset and attemptWorkPreserved round-trips are covered in
// RouteRetryEventEncodingTests.swift, split out to keep this file under the length limit.
