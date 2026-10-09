import Domain
import Foundation
import Synchronization
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-board-updates-through-the-outbox (#409): one delivery pass re-sends a write
// while Linear cannot be reached — a bounded number of times, after a backoff, honouring Retry-After —
// and every resend is a whole new try under a revalidated Lease. The resends of a pass count as one
// attempt, so a bad minute never turns a transient failure into a permanent one.

/// The waits a pass asked for, in order, without sleeping. `onSleep` runs at each one, for a test that
/// changes the world between two tries.
final class SleepLog: Sendable {
    private let waits = Mutex<[Duration]>([])
    let onSleep: @Sendable (Duration) async -> Void

    init(onSleep: @escaping @Sendable (Duration) async -> Void = { _ in }) {
        self.onSleep = onSleep
    }

    var recorded: [Duration] { waits.withLock { $0 } }

    /// The ruled schedule, with this log in place of the sleep.
    var ruled: OutboxTransientRetry {
        let rules = OutboxTransientRetry.ruled
        return OutboxTransientRetry(
            backoff: rules.backoff, longestWait: rules.longestWait, leaseMargin: rules.leaseMargin
        ) { wait in
            self.waits.withLock { $0.append(wait) }
            await self.onSleep(wait)
        }
    }
}

@Suite("Outbox: transient failures are re-sent within the pass")
struct OutboxTransientRetryTests {
    @Test("Unreachable twice, then reachable: one pass applies the write and counts no attempt")
    func unreachableTwiceThenApplied() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.unreachable("Linear answered with HTTP 503"))
        await board.refuseNext(.unreachable("Linear answered with HTTP 503"))
        let sleeps = SleepLog()
        var outbox = try outbox(journal, board: board)
        outbox.transientRetry = sleeps.ruled
        let entry = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))

        let report = try await outbox.deliverPending()

        #expect(report.deliveries.map(\.outcome) == [.applied(BoardObjectID(rawValue: "issue-1"))])
        #expect(sleeps.recorded == [.seconds(2), .seconds(8)])
        let stored = try #require(try journal.outboxEntry(clientID: entry.clientID))
        #expect(stored.state == .applied)
        #expect(stored.attemptCount < outbox.attemptLimit)
        #expect(await board.liveIssues.map(\.title) == ["Card one"])
    }

    @Test("Each resend revalidates the Lease: a Lease lost during the wait stops the resend before Linear")
    func resendRevalidatesTheLease() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.unreachable("Linear answered with HTTP 503"))
        let clock = ManualClock()
        // The run sleeps past its Lease's TTL during the first wait.
        let sleeps = SleepLog { _ in clock.advance(by: LeasePolicy.ruled.timeToLive + 1) }
        var outbox = try outbox(journal, board: board, clock: clock)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))

        await #expect {
            _ = try await outbox.deliverPending()
        } throws: { error in
            guard case OutboxError.staleRun = error else { return false }
            return true
        }
        #expect(await board.createIssueCalls == 1)
        #expect(await board.liveIssues.isEmpty)
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    @Test("A Card's Lease lost during the wait leaves its write pending, never sent again")
    func resendRevalidatesTheCardLease() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        await board.refuseNext(.unreachable("Linear answered with HTTP 503"))
        let clock = ManualClock()
        let runID = RunID()
        let cardID = try insertFixtureCard(journal, issueID: issue.rawValue)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: clock.read())
        let sleeps = SleepLog { _ in
            // Another run takes the Card during the wait.
            _ = try? journal.releaseCardLease(cardID: cardID, runID: runID)
            _ = try? journal.claimCardLease(cardID: cardID, runID: RunID(), now: clock.read())
        }
        var outbox = try outbox(journal, board: board, runID: runID, clock: clock)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(
            key: "comment:issue-1:x", write: .createComment(issue: issue, body: "hello"), cardID: cardID
        ))

        let report = try await outbox.deliverPending()

        guard case .deferred(.cardLeaseNotHeld) = report.deliveries.first?.outcome else {
            Issue.record("expected a Card Lease deferral, got \(report.deliveries)")
            return
        }
        #expect(await board.createCommentCalls == 1)
        #expect(await board.comments.isEmpty)
    }

    @Test("Always unreachable: the pass ends after a bounded number of resends and the write stays pending")
    func alwaysUnreachableStaysPending() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.script(.refuse(.unreachable("Linear answered with HTTP 503")), for: "Card one")
        let sleeps = SleepLog()
        var outbox = try outbox(journal, board: board)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))

        let report = try await outbox.deliverPending()

        guard case .deferred(.transient(let reason)) = report.deliveries.first?.outcome else {
            Issue.record("expected a transient deferral, got \(report.deliveries)")
            return
        }
        #expect(reason.contains("503"))
        #expect(sleeps.recorded == [.seconds(2), .seconds(8), .seconds(30)])
        #expect(await board.createIssueCalls == 4)
        let pending = try journal.pendingOutboxEntries()
        #expect(pending.map(\.attemptCount) == [1])
        #expect(try journal.events(ofType: .boardWriteFailed).isEmpty)
    }

    @Test("Attempts count passes, not resends: the third unreachable pass fails the write")
    func attemptLimitCountsPasses() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.script(.refuse(.unreachable("down")), for: "Card one")
        var outbox = try outbox(journal, board: board)
        outbox.transientRetry = SleepLog().ruled
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))

        let first = try await outbox.deliverPending()
        let second = try await outbox.deliverPending()
        let third = try await outbox.deliverPending()

        #expect(first.deliveries.map(\.entry.attemptCount) == [1])
        #expect(second.deliveries.map(\.entry.attemptCount) == [2])
        guard case .failed = third.deliveries.first?.outcome else {
            Issue.record("expected failed, got \(third.deliveries)")
            return
        }
        #expect(try journal.events(ofType: .boardWriteFailed).count == 1)
    }

    @Test("A Retry-After on a 503 is honoured as the wait when it is longer than the backoff")
    func retryAfterIsHonoured() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.unreachable("Linear answered with HTTP 503", retryAfter: .seconds(20)))
        let sleeps = SleepLog()
        var outbox = try outbox(journal, board: board)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))

        let report = try await outbox.deliverPending()

        #expect(sleeps.recorded == [.seconds(20)])
        #expect(report.applied.count == 1)
    }

    @Test("A Retry-After past the longest wait is honoured by not resending in this pass")
    func retryAfterPastTheCapDefers() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.unreachable("Linear answered with HTTP 503", retryAfter: .seconds(600)))
        let sleeps = SleepLog()
        var outbox = try outbox(journal, board: board)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))

        let report = try await outbox.deliverPending()

        guard case .deferred(.transient) = report.deliveries.first?.outcome else {
            Issue.record("expected a transient deferral, got \(report.deliveries)")
            return
        }
        #expect(sleeps.recorded.isEmpty)
        #expect(await board.createIssueCalls == 1)
        #expect(try journal.pendingOutboxEntries().map(\.attemptCount) == [1])
    }

    @Test("No wait outlasts the Act Lease: with too little of it left, the pass stops instead of sleeping")
    func waitNeverOutlastsTheLease() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.refuseNext(.unreachable("Linear answered with HTTP 503", retryAfter: .seconds(30)))
        let clock = ManualClock()
        let sleeps = SleepLog()
        var outbox = try outbox(journal, board: board, clock: clock)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(key: "card:1:main:1:create", write: card("Card one")))
        // 60 s of the Lease remain: a 30 s wait would leave less than the 60 s margin.
        clock.advance(by: LeasePolicy.ruled.timeToLive - 60)

        let report = try await outbox.deliverPending()

        guard case .deferred(.transient) = report.deliveries.first?.outcome else {
            Issue.record("expected a transient deferral, got \(report.deliveries)")
            return
        }
        #expect(sleeps.recorded.isEmpty)
        #expect(await board.createIssueCalls == 1)
    }

    @Test("A resent description rewrite is made from a fresh read: a human edit during the wait survives")
    func resentRewriteReadsTheDescriptionAgain() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: fencedDescription)
        await board.refuse(issue: issue, with: .unreachable("Linear answered with HTTP 502"))
        let edited = fencedDescription.replacingOccurrences(
            of: "The Operator wrote this above.", with: "Edited by hand."
        )
        let sleeps = SleepLog { _ in
            await board.edit(issue, description: edited)
            await board.clearRefusal(issue: issue)
        }
        var outbox = try outbox(journal, board: board)
        outbox.transientRetry = sleeps.ruled
        _ = try outbox.accept(OutboxWrite(
            key: "managed:issue-1:1", write: .rewriteManagedBlock(issue: issue, rendered: "new block")
        ))

        let report = try await outbox.deliverPending()

        #expect(report.applied.count == 1)
        #expect(await board.descriptionReads == 2)
        let description = try #require(await board.issue(issue)?.description)
        #expect(description.contains("Edited by hand."))
        #expect(!description.contains("The Operator wrote this above."))
        #expect(description.contains("new block"))
    }

    @Test("The wait schedule: the backoff in order, Retry-After as a floor, the longest wait as a cap")
    func scheduleArithmetic() {
        let rules = OutboxTransientRetry.ruled
        let plenty = Duration.seconds(LeasePolicy.ruled.timeToLive)
        #expect(rules.wait(beforeResend: 0, after: .unreachable("x"), leaseRemaining: plenty) == .seconds(2))
        #expect(rules.wait(beforeResend: 2, after: .unreachable("x"), leaseRemaining: plenty) == .seconds(30))
        #expect(rules.wait(beforeResend: 3, after: .unreachable("x"), leaseRemaining: plenty) == nil)
        #expect(
            rules.wait(beforeResend: 0, after: .unreachable("x", retryAfter: .seconds(1)), leaseRemaining: plenty)
                == .seconds(2)
        )
        #expect(
            rules.wait(beforeResend: 0, after: .unreachable("x", retryAfter: .seconds(61)), leaseRemaining: plenty)
                == nil
        )
        let never = OutboxTransientRetry.never
        #expect(never.wait(beforeResend: 0, after: .unreachable("x"), leaseRemaining: plenty) == nil)
    }
}
