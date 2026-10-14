import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection/maintain-the-managed-block, "budget on rewrite": a Card's block is posted as the first
// rung of its compaction ladder that fits the description budget, and a compacted post is not re-posted on
// every pass: the last posted hash is compared with every rung's.

@Suite("Managed Block maintenance: compaction")
struct ManagedBlockMaintenanceCompactionTests {
    let brief = ArchitecturalBrief(prose: "Add the endpoint.", transcriptions: [])

    @Test("A block over budget is posted compacted, the rung's hash is recorded, and the next pass skips")
    func compactedPostIsSkippedNextPass() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let runID = RunID()
        let limit = BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        let budget = try DescriptionBudget(configured: 1_100, limit: limit)
        let outbox = try outbox(journal, board: board, runID: runID, descriptionBudget: budget)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let route = try #require(Route(cli: "claude", model: "opus", effort: "high"))
        for _ in 1...3 {
            let attempt = try journal.recordAttempt(cardID: cardID, route: route, runID: runID, now: outboxEpoch)
            try journal.recordRound(
                attemptID: attempt.id, lens: .check, verdict: "failed",
                requestedChanges: String(repeating: "Fix the failing test. ", count: 20), judgedCommit: nil,
                runID: runID, now: outboxEpoch
            )
            try journal.endAttempt(attemptID: attempt.id, result: "rounds-exhausted", runID: runID, now: outboxEpoch)
        }
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: nil)

        let first = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)

        guard case .posted(let fullHash, let block, _) = first else {
            Issue.record("expected posted, got \(first)")
            return
        }
        #expect(block.outcome == .applied(nil))
        let written = try #require(await board.issue(issue)?.description)
        #expect(budget.fits(written))
        #expect(written.contains("earlier Attempts — see the Journal") || written.contains("- Attempt 1 — "))
        #expect(written.components(separatedBy: "requested changes").count < 4)  // not every Attempt kept its detail
        // The recorded hash is the posted rung's, not the full rendering's.
        let posted = try #require(try journal.managedBlockLastPostedHash(issueID: "issue-1"))
        #expect(posted != fullHash)
        let parts = try ManagedBlockFence.parts(of: written).get()
        #expect(parts.blockHash == posted)

        let updates = await board.updateCalls
        let second = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        #expect(second == .skipped(hash: fullHash))
        #expect(await board.updateCalls == updates)
    }
}
