import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// Issue #96: the land Act dispatches no Card, so a Card state write another seam deferred and
// left behind (rate limit, transient outage) is otherwise never retried once that seam released the
// Card Lease. ``DeferredCardStateReplay`` is what the land Act's own write-back runs to pick it back up.
// Split out of LandActTests.swift to stay under its file's type-body length limit.

@Suite("Land Act write-back replays a deferred Card state write (issue #96)")
struct LandActDeferredCardStateReplayTests {
    @Test("A Card state write left deferred by an earlier Act is replayed by the land Act's write-back")
    func writeBackReplaysADeferredCardStateWrite() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        let boards = try await makeBuildActBoards()
        _ = await boards.writing.seed(issue: "STALE-1", description: nil)
        // Same Cycle as the fixture's own Cards: a Project has one in-flight Cycle at a time, and this
        // Card is the one another seam left a deferred board write behind for.
        let staleCardID = try insertReconcilerCard(
            journal, cycleID: land.cycleID, issueID: "STALE-1", repository: "extra", state: .waitingOnYou
        )

        // A Card state write another seam deferred and left behind: the Journal transition landed, the
        // board write was rate-limited, and the Card Lease was released the instant it was accepted —
        // the same claim → write → release pattern `CardAutoBlock` uses.
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let setupOutbox = Outbox(
            journal: journal, board: boards.writing, runID: runID, act: .land, clock: { landEpoch }
        )
        let projection = BoardStateProjection(journal: journal, outbox: setupOutbox, scope: scope)
        _ = try journal.claimCardLease(cardID: staleCardID, runID: runID, now: landEpoch)
        await boards.writing.refuseNext(.rateLimited(retryAfter: nil, budget: nil))
        let staleRecord = try journal.card(id: staleCardID)
        let deferOutcome = try await projection.transition(card: staleRecord, to: .inProgress)
        guard case .deferred = deferOutcome else {
            Issue.record("expected the setup write to be deferred, got \(deferOutcome)")
            return
        }
        try journal.releaseCardLease(cardID: staleCardID, runID: runID)
        #expect(try journal.card(id: staleCardID).boardStateVersion == nil)

        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let act = LandAct()
        let invocation = EngineInvocation(
            // Forced: the stale Card sitting In Progress makes the scheduled trigger's own
            // `cycleHasUnfinishedCards` check refuse to fire — irrelevant to what this test is about.
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .forced,
            runID: runID, board: board, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        let staleIssue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "STALE-1")))
        #expect(staleIssue.workflowState == scope.states[.inProgress])
        #expect(try journal.card(id: staleCardID).boardStateVersion == 1)
        #expect(try journal.currentCardLease(cardID: staleCardID) == nil)
        let reposted = try journal.events(ofType: .boardStateReposted)
        #expect(reposted.count == 1)
        guard case .boardStateReposted(let cards) = try #require(reposted.first).event else {
            Issue.record("expected boardStateReposted")
            return
        }
        #expect(cards == 1)
    }
}
