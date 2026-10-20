import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/read-board-changes-by-delta, `sync-boundary` (roadmap P22.3): every page of both roots is
// read once, by its own cursor; the boundary is inclusive and deduplicated, so an equal timestamp or a late
// arrival is read rather than lost; nothing moves until the last page is processed; an incomplete or refused
// read moves no cursor and its retry is idempotent; an empty delta never drops a tracked object.

private func readerLeased(
    _ journal: JournalStore, board: FakeReadingBoard, act: Act = .build, horizon: Date = .distantFuture,
    requestLimit: Int = 40, acceptsReReady: Bool = true
) throws -> (DeltaRead, RunID) {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: act, runID: runID, mode: .rehearsal, now: deltaEpoch) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    var read = DeltaRead(
        journal: journal, board: board, runID: runID, act: act, clock: { deltaEpoch }, horizon: { horizon }
    )
    read.requestLimit = requestLimit
    read.acceptsReReady = acceptsReReady
    return (read, runID)
}

private func at(_ seconds: TimeInterval) -> Date {
    deltaEpoch.addingTimeInterval(seconds)
}

@Suite("Delta Read paging and cursors")
struct DeltaReadPagingTests {
    // MARK: - Boundaries

    @Test("An equal updatedAt on the sync boundary is read again and deduplicated, so nothing is lost or doubled")
    func equalTimestampAcrossTheBoundary() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let first = FakeReadingBoard([
            page(
                objects: [object("card-1", state: stateTodo, updatedAt: 10)],
                comments: [comment("c-1", on: "card-1", author: humanAuthor, createdAt: 10)]
            )
        ])
        let (firstRead, _) = try readerLeased(journal, board: first)
        _ = try await firstRead.perform()
        #expect(try journal.releaseActLease(runID: firstRead.runID))

        // A second issue and a second comment are stamped at exactly the cursor, after the first read.
        let second = FakeReadingBoard([
            page(
                objects: [
                    object("card-1", state: stateTodo, updatedAt: 10),
                    object("other", state: stateTodo, updatedAt: 10)
                ],
                comments: [
                    comment("c-1", on: "card-1", author: humanAuthor, createdAt: 10),
                    comment("c-2", on: "card-1", author: humanAuthor, createdAt: 10)
                ]
            )
        ])
        let (secondRead, _) = try readerLeased(journal, board: second)
        guard case .read(let report) = try await secondRead.perform() else {
            Issue.record("expected a read")
            return
        }

        let calls = await second.calls
        #expect(calls.map(\.since) == [at(10)], "the boundary is inclusive: the cursor itself is read again")
        #expect(calls.map(\.commentsSince) == [at(10)])
        #expect(report.unknownObjects.map(\.id.rawValue) == ["other"], "the revision already observed is dropped")
        #expect(report.humanComments.map(\.comment.id.rawValue) == ["c-2"], "the comment already recorded is dropped")
        #expect(try journal.events(ofType: .humanCardComment).count == 2, "c-1 once, c-2 once")
        #expect(try journal.card(id: cardID).state == .todo)
    }

    @Test("A newer revision of an observed issue is read, an older or equal one is not")
    func revisionDecidesDeduplication() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([
            page(objects: [object("card-1", state: stateTodo, updatedAt: 10)]),
            page(objects: [object("card-1", state: stateTodo, updatedAt: 10)]),
            page(objects: [object("card-1", state: stateTodo, description: "edited", updatedAt: 11)])
        ])

        var reported: [Int] = []
        for _ in 0..<3 {
            let (read, _) = try readerLeased(journal, board: board)
            guard case .read(let report) = try await read.perform() else {
                Issue.record("expected a read")
                return
            }
            reported.append(report.cardChanges.count)
            _ = try journal.releaseActLease(runID: read.runID)
        }

        #expect(reported == [1, 0, 1])
    }

    @Test("A comment newer than an unread issue change does not move the issues' cursor past it")
    func commentDoesNotSkipAnIssueChange() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let first = FakeReadingBoard([
            page(
                objects: [object("f-1", state: stateTodo, updatedAt: 30)],
                comments: [comment("c-1", on: "f-1", author: humanAuthor, createdAt: 100)]
            )
        ])
        let (firstRead, _) = try readerLeased(journal, board: first)
        _ = try await firstRead.perform()
        #expect(try journal.releaseActLease(runID: firstRead.runID))

        let sync = try #require(try journal.boardSyncPoint())
        #expect(sync.issuesSynced == at(30))
        #expect(sync.commentsSynced == at(100))

        // An issue change stamped before the comment shows up afterwards; the single-cursor read lost it.
        let second = FakeReadingBoard([page(objects: [object("f-2", state: stateTodo, updatedAt: 60)])])
        let (secondRead, _) = try readerLeased(journal, board: second)
        guard case .read(let report) = try await secondRead.perform() else {
            Issue.record("expected a read")
            return
        }

        let call = try #require(await second.calls.first)
        #expect(call.since == at(30))
        #expect(call.commentsSince == at(100))
        #expect(report.unknownObjects.map(\.id.rawValue) == ["f-2"])
    }

    @Test("A change that arrives while pages are being read stays eligible: the cursor is held behind the horizon")
    func midPaginationArrivalIsReadNextTime() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let horizon = at(1_000)
        // f-1 is stamped just before the read started; f-2 changed after it started and was not returned.
        let first = FakeReadingBoard([page(objects: [object("f-1", state: stateTodo, updatedAt: 995)])])
        let (firstRead, _) = try readerLeased(journal, board: first, horizon: horizon)
        _ = try await firstRead.perform()
        #expect(try journal.releaseActLease(runID: firstRead.runID))

        let cursor = try #require(try journal.boardSyncPoint()?.issuesSynced)
        #expect(cursor == horizon.addingTimeInterval(-DeltaRead.syncOverlap))
        #expect(cursor < at(995), "the cursor never passes the horizon's overlap, whatever was observed")

        let second = FakeReadingBoard([
            page(objects: [
                object("f-1", state: stateTodo, updatedAt: 995),
                object("f-2", state: stateTodo, updatedAt: 1_005)
            ])
        ])
        let (secondRead, _) = try readerLeased(journal, board: second, horizon: at(2_000))
        guard case .read(let report) = try await secondRead.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(await second.calls.map(\.since) == [cursor])
        #expect(report.unknownObjects.map(\.id.rawValue) == ["f-2"], "f-1 is deduplicated, f-2 is seen")
    }

    // MARK: - Interruption

    @Test("An interruption after page 2 moves no cursor and stores nothing; the retry is idempotent")
    func interruptionLeavesNothingAndRetryIsIdempotent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let pages: [Result<BoardDelta, BoardError>] = [
            page(
                objects: [object("card-1", state: stateShelved, updatedAt: 1)],
                comments: [comment("c-1", on: "card-1", author: humanAuthor, createdAt: 2)],
                nextObjectCursor: BoardCursor(rawValue: "o-2")
            ),
            page(
                objects: [object("f-2", state: stateTodo, updatedAt: 3)],
                nextObjectCursor: BoardCursor(rawValue: "o-3")
            )
        ]
        let interrupted = FakeReadingBoard(pages + [.failure(.unreachable("connection lost"))])
        let (firstRead, _) = try readerLeased(journal, board: interrupted)
        await #expect(throws: DeltaReadError.boardUnavailable(.unreachable("connection lost"))) {
            try await firstRead.perform()
        }
        #expect(try journal.releaseActLease(runID: firstRead.runID))

        #expect(try journal.boardSyncPoint() == nil)
        #expect(try journal.observedIssueRevisions(["card-1", "f-2"]).isEmpty)
        #expect(try journal.observedCommentIDs(["c-1"]).isEmpty)
        #expect(try journal.card(id: cardID).state == .todo, "a Shelved seen on page 1 is not applied")

        let retry = FakeReadingBoard(pages + [page(objects: [object("f-3", state: stateTodo, updatedAt: 4)])])
        let (retryRead, _) = try readerLeased(journal, board: retry)
        guard case .read(let report) = try await retryRead.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.requests == 3)
        #expect(try journal.card(id: cardID).state == .shelved)
        #expect(report.unknownObjects.map(\.id.rawValue) == ["f-2", "f-3"])
        #expect(try journal.boardSyncPoint()?.issuesSynced == at(4))
        #expect(try journal.events(ofType: .cardShelved).count == 1)
        #expect(try journal.events(ofType: .humanCardComment).count == 1)
        #expect(try journal.events(ofType: .deltaReadCompleted).count == 1)
    }

    @Test("A rate refusal after page 2 degrades the read and moves no cursor")
    func rateRefusalAfterPageTwo() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeReadingBoard([
            page(
                objects: [object("f-1", state: stateTodo, updatedAt: 1)],
                nextObjectCursor: BoardCursor(rawValue: "o-2")
            ),
            page(
                objects: [object("f-2", state: stateTodo, updatedAt: 2)],
                nextObjectCursor: BoardCursor(rawValue: "o-3")
            ),
            .failure(.rateLimited(retryAfter: nil, budget: nil))
        ])
        let (read, _) = try readerLeased(journal, board: board)

        guard case .degraded(let reason) = try await read.perform() else {
            Issue.record("expected a degraded read")
            return
        }

        #expect(reason.contains("3 request(s)"))
        #expect(try journal.boardSyncPoint() == nil)
        #expect(try journal.observedIssueRevisions(["f-1", "f-2"]).isEmpty)
    }

    @Test("Reaching the request cap checkpoints the pass: recorded, applied so far, no time cursor moves")
    func requestCapCheckpointsThePass() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let cardID = try insertCard(journal, issueID: "card-1", state: .todo)
        let board = FakeReadingBoard([
            page(
                objects: [object("card-1", state: stateShelved, updatedAt: 1)],
                nextObjectCursor: BoardCursor(rawValue: "o-2")
            ),
            page(
                objects: [object("f-2", state: stateTodo, updatedAt: 2)],
                nextObjectCursor: BoardCursor(rawValue: "o-3")
            ),
            page(objects: [object("f-3", state: stateTodo, updatedAt: 3)])
        ])
        let (read, _) = try readerLeased(journal, board: board, requestLimit: 2)

        guard case .degraded(let reason) = try await read.perform() else {
            Issue.record("expected an incomplete read")
            return
        }

        #expect(reason.contains("did not reach the last page"))
        #expect(await board.calls.count == 2)
        let sync = try #require(try journal.boardSyncPoint())
        #expect(sync.issuesSynced == nil && sync.commentsSynced == nil, "no time cursor moved")
        #expect(sync.pass?.issues.after == "o-3")
        #expect(sync.pass?.issues.done == false)
        #expect(sync.pass?.comments.done == true)
        #expect(try journal.card(id: cardID).state == .shelved, "the pages read are applied, once")
        #expect(try journal.observedIssueRevisions(["f-2"]).count == 1)
        #expect(try journal.events(ofType: .deltaReadIncomplete).count == 1)
        #expect(try journal.events(ofType: .deltaReadCompleted).isEmpty)
        #expect(try journal.events(ofType: .rateBudgetExhausted).isEmpty)
    }

    @Test("An over-cap read resumes across Acts, each page requested once, the cursor moves on the last Act only")
    func overCapReadResumesAcrossActs() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let pages = (1...5).map { number in
            page(
                objects: [object("f-\(number)", state: stateTodo, updatedAt: TimeInterval(number))],
                comments: number == 1 ? [comment("c-1", on: "f-1", author: humanAuthor, createdAt: 9)] : [],
                nextObjectCursor: number < 5 ? BoardCursor(rawValue: "o-\(number + 1)") : nil
            )
        }
        let board = FakeReadingBoard(pages)

        var outcomes: [Bool] = []
        for act in 0..<3 {
            let (read, _) = try readerLeased(journal, board: board, requestLimit: 2)
            let outcome = try await read.perform()
            if case .read = outcome { outcomes.append(true) } else { outcomes.append(false) }
            let sync = try #require(try journal.boardSyncPoint())
            if act < 2 {
                #expect(sync.issuesSynced == nil, "the cursor does not move before the pass completes")
                #expect(try journal.events(ofType: .deltaReadCompleted).isEmpty)
            }
            #expect(try journal.releaseActLease(runID: read.runID))
        }

        #expect(outcomes == [false, false, true])
        let calls = await board.calls
        #expect(calls.map(\.objectsAfter) == [
            nil, BoardCursor(rawValue: "o-2"), BoardCursor(rawValue: "o-3"),
            BoardCursor(rawValue: "o-4"), BoardCursor(rawValue: "o-5")
        ], "every page is requested exactly once; each Act resumes from the checkpoint")
        #expect(calls.map(\.skippedComments) == [false, true, true, true, true])
        #expect(try journal.observedIssueRevisions((1...5).map { "f-\($0)" }).count == 5, "nothing lost")
        let sync = try #require(try journal.boardSyncPoint())
        #expect(sync.issuesSynced == at(5))
        #expect(sync.commentsSynced == at(9))
        #expect(sync.pass == nil)
        #expect(try journal.events(ofType: .deltaReadCompleted).count == 1)
        #expect(try journal.events(ofType: .deltaReadIncomplete).count == 2)
    }

    @Test("A checkpointed cursor the board refuses as stale restarts that root from its time cursor")
    func staleCheckpointRestartsTheRoot() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let first = FakeReadingBoard([
            page(
                objects: [object("f-1", state: stateTodo, updatedAt: 1)],
                nextObjectCursor: BoardCursor(rawValue: "o-2")
            )
        ])
        let (firstRead, _) = try readerLeased(journal, board: first, requestLimit: 1)
        _ = try await firstRead.perform()
        #expect(try journal.releaseActLease(runID: firstRead.runID))
        #expect(try journal.boardSyncPoint()?.pass?.issues.after == "o-2")

        let second = FakeReadingBoard([
            .failure(.refused("invalid cursor")),
            page(objects: [
                object("f-1", state: stateTodo, updatedAt: 1), object("f-2", state: stateTodo, updatedAt: 2)
            ])
        ])
        let (secondRead, _) = try readerLeased(journal, board: second)
        guard case .read(let report) = try await secondRead.perform() else {
            Issue.record("expected the restarted read to complete")
            return
        }

        let calls = await second.calls
        #expect(calls.map(\.objectsAfter) == [BoardCursor(rawValue: "o-2"), nil])
        #expect(calls.map(\.since) == [nil, nil], "the restart keeps the pass's since")
        #expect(report.unknownObjects.map(\.id.rawValue) == ["f-2"], "f-1 was stored by the first Act")
        #expect(try journal.events(ofType: .deltaReadIncomplete).count == 2, "the restart is recorded")
        let sync = try #require(try journal.boardSyncPoint())
        #expect(sync.issuesSynced == at(2) && sync.pass == nil)
    }

    // MARK: - Tracked state

    @Test("An empty delta never drops a tracked Card, and an unknown issue in a delta is not adopted")
    func emptyDeltaKeepsTrackedObjects() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let inFlight = try insertCard(journal, issueID: "in-flight", state: .inProgress)
        let terminal = try insertCard(journal, issueID: "terminal", state: .done)
        let blocked = try insertCard(journal, issueID: "halted", state: .blocked)
        let before = try [inFlight, terminal, blocked].map { try journal.card(id: $0) }

        let board = FakeReadingBoard([
            page(),
            page(objects: [object("stranger", state: stateTodo, updatedAt: 5)])
        ])
        let (empty, _) = try readerLeased(journal, board: board)
        guard case .read(let emptyReport) = try await empty.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(emptyReport.cardChanges.isEmpty)
        #expect(try journal.releaseActLease(runID: empty.runID))
        #expect(try journal.boardSyncPoint() == nil, "an empty first read has no cursor to move")

        let (stranger, _) = try readerLeased(journal, board: board)
        guard case .read(let report) = try await stranger.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.unknownObjects.map(\.id.rawValue) == ["stranger"])
        #expect(try journal.card(issueID: "stranger") == nil)
        #expect(try [inFlight, terminal, blocked].map { try journal.card(id: $0) } == before)
    }
}
