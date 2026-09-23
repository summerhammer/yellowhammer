import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// Issue #96: split out of BoardStateProjectionTests.swift to stay under its file's type-body
// length limit. `reclaimingExpiredLeases: false` (``DeferredCardStateReplay``'s own call shape) never
// takes over another run's expired Card Lease, and `repost` stops the moment a Card's outcome is a
// budget deferral — acting on a budget that is gone does less than waiting.

@Suite("Board state projection: reclaiming and budget deferrals (issue #96)")
struct BoardStateProjectionReplayTests {
    @Test("repost with reclaimingExpiredLeases: false skips a Card whose lease is an expired other run's")
    func repostNonReclaimingSkipsExpiredOtherRunLease() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        let deadRunID = RunID()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: outboxEpoch
        )
        // A dead run's expired Card Lease, still on the row: `ExpiredLeaseSweep` has not run yet.
        _ = try journal.claimCardLease(cardID: cardID, runID: deadRunID, now: outboxEpoch)
        let record = try journal.card(id: cardID)

        let outcomes = try await projection.repost([record], reclaimingExpiredLeases: false)

        #expect(outcomes.isEmpty)
        #expect(await boards.writing.updateCalls == 0)
        #expect(try journal.card(id: cardID).boardStateVersion == nil)
        #expect(try journal.currentCardLease(cardID: cardID)?.runID == deadRunID)
    }

    @Test("repost stops after a rate-limited deferral, leaves the rest unposted and no Lease held by it")
    func repostStopsAfterRateLimitedDeferral() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        _ = await boards.writing.seed(issue: "issue-2", description: nil)
        let firstCardID = try insertFixtureCard(journal, issueID: "issue-1")
        let secondCardID = try insertFixtureCard(journal, issueID: "issue-2")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        _ = try journal.transitionCard(
            cardID: firstCardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: outboxEpoch
        )
        _ = try journal.transitionCard(
            cardID: secondCardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: outboxEpoch
        )
        await boards.writing.refuseNext(.rateLimited(retryAfter: nil, budget: nil))

        let outcomes = try await projection.repost()

        #expect(outcomes.count == 1)
        let first = try #require(outcomes.first)
        guard case .deferred(let record, let delivery) = first else {
            Issue.record("expected deferred, got \(first)")
            return
        }
        #expect(record.id == firstCardID)
        #expect(delivery.outcome == .deferred(.rateLimited(retryAfter: nil)))
        #expect(await boards.writing.updateCalls == 1)
        #expect(try journal.card(id: firstCardID).boardStateVersion == nil)
        #expect(try journal.card(id: secondCardID).boardStateVersion == nil)
        #expect(try journal.currentCardLease(cardID: firstCardID) == nil)
        #expect(try journal.currentCardLease(cardID: secondCardID) == nil)

        // A following repost, with the budget no longer refusing, posts both.
        let secondPass = try await projection.repost()
        #expect(secondPass.count == 2)
        #expect(await boards.writing.updateCalls == 3)
        #expect(try journal.card(id: firstCardID).boardStateVersion == 1)
        #expect(try journal.card(id: secondCardID).boardStateVersion == 1)
    }
}
