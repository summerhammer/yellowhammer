import Domain
@testable import Engine
import Foundation
import Journal
import Synchronization
import Testing

// operations/retry-transient-linear-failures (issue #409, item 2): the land Act that closes the Night
// says out loud when the Night Card's completion could not be delivered, instead of exiting as if it had.

private final class LineLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ line: String) { storage.withLock { $0.append(line) } }
    var lines: [String] { storage.withLock { $0 } }
}

private final class ClosedPosts: Sendable {
    private let storage = Mutex<Int>(0)
    func record(_ notification: ExceptionNotification) {
        if case .closed = notification.event { storage.withLock { $0 += 1 } }
    }
    var count: Int { storage.withLock { $0 } }
}

@Suite("Night Card completion that stays pending when the Night closes")
struct NightCardCompletionDeferredTests {
    @Test("A completion the board cannot take is recorded and logged once, and a later Act delivers it")
    func deferredCompletionIsRecordedAndLogged() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let writing = boards.writing
        let board = ActBoard(reading: FakeReadingBoard([]), writing: writing, provisioning: boards.provisioning)
        let log = LineLog()
        let closed = ClosedPosts()
        let landRun = RunID()
        let issueID = Mutex<String?>(nil)

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: landRun, closesNight: true, board: board,
            notifier: ExceptionNotifier { closed.record($0) },
            outboxTransientRetry: SleepLog().ruled, actLog: { log.append($0) },
            work: { context in
                let issue = try #require(context.night.nightCardIssueID)
                issueID.withLock { $0 = issue }
                await writing.refuse(issue: BoardObjectID(rawValue: issue), with: .unreachable("simulated outage"))
            }
        ).run()

        let pending = try journal.pendingOutboxEntries()
        #expect(pending.count == 2)
        let deferred = try journal.events(ofType: .nightCardCompletionDeferred)
        #expect(deferred.count == 1)
        let record = try #require(deferred.first)
        #expect(record.runID == landRun)
        #expect(record.act == .land)
        guard case .nightCardCompletionDeferred(let eventIssue, let entryIDs, let reason) = record.event else {
            Issue.record("Event is not nightCardCompletionDeferred")
            return
        }
        #expect(eventIssue == issueID.withLock { $0 })
        #expect(entryIDs == pending.map(\.id))
        #expect(!reason.isEmpty)
        #expect(log.lines.count == 1)
        #expect(log.lines.first?.contains("deferred") == true)
        #expect(try journal.events(ofType: .nightClosed).count == 1)
        #expect(closed.count == 1)
        #expect(try journal.events().map(\.type).contains(.nightCardCompleted) == false)

        // A later Act flushes it once the board is reachable again.
        await writing.clearRefusal(issue: BoardObjectID(rawValue: try #require(issueID.withLock { $0 })))
        try await EngineInvocation(
            act: .build, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, outboxTransientRetry: SleepLog().ruled,
            work: { context in _ = try await context.outbox?.deliverPending() }
        ).run()

        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(try journal.events(ofType: .nightClosed).count == 1)
        #expect(try journal.events(ofType: .nightCardCompletionDeferred).count == 1)
    }

    @Test("A completion delivered on the closing Act records nothing deferred and logs nothing")
    func deliveredCompletionRecordsNothingDeferred() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let log = LineLog()

        try await EngineInvocation(
            act: .land, mode: .real, nightStart: nightCardNightStart, journal: journal,
            trigger: .forced, runID: RunID(), closesNight: true, board: board,
            outboxTransientRetry: SleepLog().ruled, actLog: { log.append($0) },
            work: { _ in }
        ).run()

        #expect(try journal.events(ofType: .nightCardCompletionDeferred).isEmpty)
        #expect(try journal.events(ofType: .nightCardCompleted).count == 1)
        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(log.lines.isEmpty)
    }
}
