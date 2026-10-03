import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-board-updates-through-the-outbox: every board write is accepted into the
// Project's Journal before it is sent, under a deterministic client id; the run's Lease is revalidated
// immediately before each write; a permanent failure is recorded for the Night Summary. These run
// against an in-memory Linear stand-in, which is what a rehearsal may assert: Outbox idempotency and
// replay after a killed run.

@Suite("Outbox")
struct OutboxTests {
    // Client id determinism, salting and shape moved to OutboxClientIDTests.swift (SwiftLint's
    // type_body_length).

    // MARK: - Accepting

    @Test("Accepting persists the write in the Journal and sends nothing to Linear")
    func acceptPersistsWithoutSending() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let outbox = try outbox(journal, board: board)

        let write = OutboxWrite(key: "night-card:2026-09-15:create", write: card("Night 2026-09-15"))
        let entry = try outbox.accept(write)

        #expect(entry.state == .pending)
        #expect(entry.clientID == outbox.clientID(for: "night-card:2026-09-15:create"))
        #expect(entry.operation == "issueCreate")
        #expect(try journal.pendingOutboxEntries().map(\.id) == [entry.id])
        #expect(await board.createIssueCalls == 0)
    }

    @Test("Accepting the same key twice returns the one entry")
    func acceptIsIdempotent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let outbox = try outbox(journal, board: FakeWritingBoard())
        let issue = BoardObjectID(rawValue: "issue-1")
        let write = OutboxWrite(key: "comment:issue-1:crash", write: .createComment(issue: issue, body: "x"))

        let first = try outbox.accept(write)
        let second = try outbox.accept(write)

        #expect(first == second)
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    @Test("A description is written only through the fenced rewrite: an update carrying one is refused")
    func descriptionUpdateRefusedAtAccept() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let outbox = try outbox(journal, board: FakeWritingBoard())
        let write = OutboxWrite(
            key: "bad",
            write: .updateIssue(
                issue: BoardObjectID(rawValue: "i"), change: BoardIssueChange(description: "x"), undo: nil
            )
        )

        #expect(throws: OutboxError.descriptionNotFenced(key: "bad")) {
            try outbox.accept(write)
        }
        #expect(try journal.pendingOutboxEntries().isEmpty)
    }

    // MARK: - Replay

    @Test("Replay after a killed run creates no duplicate issue: Linear's conflict on insert counts as applied")
    func replayAfterKilledRunCreatesNoDuplicate() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let clock = ManualClock()
        let write = OutboxWrite(key: "card:1:main:1:create", write: card("Card one"))

        // Run A: Linear applies the create, then the process dies before the Journal hears of it.
        let runA = RunID()
        let killed = try outbox(journal, board: board, runID: runA, clock: clock) { _ in throw SimulatedCrash() }
        _ = try killed.accept(write)
        await #expect(throws: SimulatedCrash.self) { try await killed.deliverPending() }
        #expect(await board.liveIssues.count == 1)
        #expect(try journal.pendingOutboxEntries().count == 1)

        // Run B, after A's Lease expired: replays the pending entry under the same client id.
        clock.advance(by: 700)
        let resumed = try outbox(journal, board: board, runID: RunID(), clock: clock)
        let report = try await resumed.deliverPending()

        #expect(report.deliveries.count == 1)
        #expect(report.deliveries[0].outcome == .alreadyApplied(BoardObjectID(rawValue: "issue-1")))
        #expect(await board.liveIssues.count == 1)
        #expect(await board.createIssueCalls == 2)
        let entry = try #require(try journal.outboxEntry(clientID: killed.clientID(for: write.key)))
        #expect(entry.state == .applied)
        #expect(entry.result == "issue-1")
        #expect(try journal.pendingOutboxEntries().isEmpty)
    }

    @Test("A lost response is re-attempted, and the re-attempt creates no duplicate comment")
    func lostResponseReplaysWithoutDuplicate() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        await board.script(.loseResponse, for: "Attempt 1 crashed")
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(
            key: "comment:issue-1:attempt-1:crash", write: .createComment(issue: issue, body: "Attempt 1 crashed")
        )

        let first = try await outbox.post(write)
        guard case .deferred(.transient) = first.outcome else {
            Issue.record("expected a transient deferral, got \(first.outcome)")
            return
        }
        #expect(first.entry.attemptCount == 1)

        let second = try await outbox.deliverPending()

        #expect(second.deliveries.map(\.outcome) == [.alreadyApplied(BoardObjectID(rawValue: "comment-1"))])
        #expect(await board.comments.count == 1)
        #expect(try journal.pendingOutboxEntries().isEmpty)
    }

    @Test("Repeated transient failures become a permanent one, recorded for the Night Summary")
    func transientFailuresBecomePermanent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        for _ in 0..<3 { await board.refuseNext(.unreachable("down")) }
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(key: "card:1:main:1:create", write: card("Card one"))

        _ = try outbox.accept(write)
        _ = try await outbox.deliverPending()
        _ = try await outbox.deliverPending()
        let third = try await outbox.deliverPending()

        guard case .failed = third.deliveries[0].outcome else {
            Issue.record("expected failed, got \(third.deliveries[0].outcome)")
            return
        }
        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(try journal.events(ofType: .boardWriteFailed).count == 1)
    }

    @Test("An HTTP 503 transient failure leaves the entry pending rather than failed")
    func http503LeavesEntryPending() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.unreachable("Linear answered with HTTP 503"))
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(key: "card:1:main:1:create", write: card("Card one"))

        _ = try outbox.accept(write)
        let delivery = try await outbox.deliverPending()

        guard case .deferred(.transient(let reason)) = delivery.deliveries[0].outcome else {
            Issue.record("expected transient deferral, got \(delivery.deliveries[0].outcome)")
            return
        }
        #expect(reason.contains("503"))
        #expect(try journal.pendingOutboxEntries().count == 1)
        #expect(try journal.events(ofType: .boardWriteFailed).isEmpty)
    }

    // MARK: - Leases

    @Test("A write on a Card whose Lease another run holds never reaches Linear")
    func staleCardLeaseWriteNeverReachesLinear() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: issue.rawValue)
        let outbox = try outbox(journal, board: board)
        // Another run holds the Card.
        _ = try journal.claimCardLease(cardID: cardID, runID: RunID(), now: outboxEpoch)

        let delivery = try await outbox.post(
            OutboxWrite(key: "comment:issue-1:1", write: .createComment(issue: issue, body: "hello"), cardID: cardID)
        )

        guard case .deferred(.cardLeaseNotHeld) = delivery.outcome else {
            Issue.record("expected the write deferred for the Card's Lease, got \(delivery.outcome)")
            return
        }
        #expect(await board.createCommentCalls == 0)
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    @Test("A write on a Card this run holds is delivered, and one whose Lease expired is not")
    func cardLeaseHeldThenExpired() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: issue.rawValue)
        let clock = ManualClock()
        let runID = RunID()
        let outbox = try outbox(journal, board: board, runID: runID, clock: clock)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: clock.read())

        let held = try await outbox.post(
            OutboxWrite(key: "comment:issue-1:1", write: .createComment(issue: issue, body: "one"), cardID: cardID)
        )
        #expect(held.outcome == .applied(BoardObjectID(rawValue: "comment-1")))

        // The Mac slept: the Card's Lease expired, but the Act's is refreshed as the heartbeat would.
        clock.advance(by: 601)
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: clock.read())
        let expired = try await outbox.post(
            OutboxWrite(key: "comment:issue-1:2", write: .createComment(issue: issue, body: "two"), cardID: cardID)
        )

        guard case .deferred(.cardLeaseNotHeld) = expired.outcome else {
            Issue.record("expected the write deferred, got \(expired.outcome)")
            return
        }
        #expect(await board.createCommentCalls == 1)
    }

    @Test("A run whose Act-scoped Lease is lost writes nothing and stops")
    func staleRunWritesNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let clock = ManualClock()
        let outbox = try outbox(journal, board: board, clock: clock)
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))
        // Another run took the Project after this one's Lease expired.
        clock.advance(by: 700)
        _ = try journal.claimActLease(act: .build, runID: RunID(), mode: .rehearsal, now: clock.read())

        await #expect(throws: OutboxError.self) { try await outbox.deliverPending() }

        #expect(await board.createIssueCalls == 0)
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    // MARK: - Failures

    @Test("A permanent refusal is recorded in the event log with the operation and issue")
    func permanentFailureIsRecorded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        await board.refuseNext(.refused("Linear reports no such state"))
        let outbox = try outbox(journal, board: board)
        let write = OutboxWrite(
            key: "state:issue-1:done",
            write: .updateIssue(
                issue: issue, change: BoardIssueChange(workflowState: BoardObjectID(rawValue: "s")), undo: nil
            )
        )

        let delivery = try await outbox.post(write)

        guard case .failed = delivery.outcome else {
            Issue.record("expected failed, got \(delivery.outcome)")
            return
        }
        #expect(delivery.entry.state == .failed)
        let events = try journal.events(ofType: .boardWriteFailed)
        #expect(events.count == 1)
        guard case .boardWriteFailed(let clientID, let operation, let issueID, _)? = events.first?.event else {
            Issue.record("expected boardWriteFailed")
            return
        }
        #expect(clientID == outbox.clientID(for: write.key))
        #expect(operation == "issueUpdate")
        #expect(issueID == "issue-1")
    }

    @Test("A rate-limit refusal names the Outbox's App Installation and workspace when it has one")
    func rateLimitNamesTheInstallation() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.rateLimited(retryAfter: nil, budget: nil))
        let label = AppInstallationLabel(name: "acme", workspace: BoardObjectID(rawValue: "workspace-1"))
        let outbox = try outbox(journal, board: board, installation: label)
        _ = try outbox.accept([OutboxWrite(key: "card:1:main:1:create", write: card("Card one"))])

        _ = try await outbox.deliverPending()

        let event = try #require(try journal.events(ofType: .rateBudgetExhausted).first?.event)
        guard case .rateBudgetExhausted(_, let recorded) = event else {
            Issue.record("Event is not rateBudgetExhausted")
            return
        }
        #expect(recorded == label)
        #expect(event.payload?["installation"] == "acme")
        #expect(event.payload?["workspace"] == "workspace-1")
    }

    @Test("A rate-limit refusal leaves the write pending, stops delivery, and names the budget installation-wide")
    func rateLimitIsInstallationWide() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.rateLimited(retryAfter: .seconds(30), budget: nil))
        let outbox = try outbox(journal, board: board)
        _ = try outbox.accept([
            OutboxWrite(key: "card:1:main:1:create", write: card("Card one")),
            OutboxWrite(key: "card:1:main:2:create", write: card("Card two"))
        ])

        let report = try await outbox.deliverPending()

        #expect(report.deliveries.map(\.outcome) == [.deferred(.rateLimited(retryAfter: .seconds(30)))])
        #expect(await board.createIssueCalls == 1)
        #expect(try journal.pendingOutboxEntries().count == 2)
        let events = try journal.events(ofType: .rateBudgetExhausted)
        #expect(events.count == 1)
        #expect(events.first?.event.payload?["budget"] == "installation-wide")
        #expect(events.first?.event.payload?["installation"] == nil)

        // The budget came back: both are delivered, in order.
        let retry = try await outbox.deliverPending()
        #expect(retry.applied.count == 2)
        #expect(await board.liveIssues.map(\.title) == ["Card one", "Card two"])
    }
}
