import Domain
import Foundation
import GRDB
import Testing

@testable import Engine
@testable import Journal

// board-projection/maintain-the-managed-block (P5.6): the Card's block is rendered from the Journal
// and posted through the Outbox; a rewrite is not issued when the hash of the rendered block equals
// the hash of what was last posted; disposition labels stay in step with the block and their groups
// stay mutually exclusive; nothing is posted to a Cancelled Card. Rehearsal-assertable against the
// in-memory board.

@Suite("Managed Block maintenance")
struct ManagedBlockMaintenanceTests {
    let brief = ArchitecturalBrief(prose: "Add the endpoint.", transcriptions: [])

    // MARK: - Hash-skip

    @Test("The first maintenance posts the block and the labels; an unchanged block is skipped")
    func hashSkip() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(
            issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: "stale")
        )
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try heldOutbox(journal, board: board, cardID: cardID)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: labels)

        let first = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        guard case .posted(let hash, let block, let labelDelivery) = first else {
            Issue.record("expected posted, got \(first)")
            return
        }
        #expect(block.outcome == .applied(nil))
        #expect(labelDelivery?.outcome == .applied(nil))
        let parts = try ManagedBlockFence.parts(of: await board.issue(issue)?.description).get()
        #expect(parts.blockHash == hash)
        #expect(parts.block.contains("**Repository:** `main`"))
        #expect(parts.block.hasSuffix(CardManagedBlock.footer))
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == hash)

        let updates = await board.updateCalls
        let reads = await board.descriptionReads
        let written = try journal.events(ofType: .managedBlockWritten).count
        let pending = try journal.pendingOutboxEntries().count

        let second = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        #expect(second == .skipped(hash: hash))
        #expect(await board.updateCalls == updates)
        #expect(await board.descriptionReads == reads)
        #expect(try journal.events(ofType: .managedBlockWritten).count == written)
        #expect(try journal.pendingOutboxEntries().count == pending)
    }

    @Test("A new Round changes the rendered block, so it is posted again under a new hash")
    func changedBlockIsReposted() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let runID = RunID()
        let outbox = try heldOutbox(journal, board: board, cardID: cardID, runID: runID)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: nil)

        let first = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        guard case .posted(let before, _, _) = first else {
            Issue.record("expected posted, got \(first)")
            return
        }
        let route = try #require(Route(cli: "claude", model: "opus", effort: "high"))
        let attempt = try journal.recordAttempt(cardID: cardID, route: route, runID: runID, now: outboxEpoch)
        try journal.recordRound(
            attemptID: attempt.id, lens: .check, verdict: "failed", requestedChanges: nil, judgedCommit: nil,
            runID: runID, now: outboxEpoch
        )

        let outcome = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        guard case .posted(let after, _, _) = outcome else {
            Issue.record("expected posted, got \(outcome)")
            return
        }
        #expect(after != before)
        let description = try #require(await board.issue(issue)?.description)
        #expect(description.contains("#### Attempt 1 — `claude/opus/high`"))
        #expect(description.contains("- Check: failed"))
        #expect(description.contains("1. check — failed"))
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == after)
    }

    @Test("An aborted rewrite records no hash, so the next maintenance tries again rather than skipping")
    func abortedRewriteDoesNotSkip() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.seed(issue: "issue-1", description: "no delimiters here")
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try heldOutbox(journal, board: board, cardID: cardID)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: nil)

        let first = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        guard case .posted(_, let block, _) = first, case .aborted = block.outcome else {
            Issue.record("expected an aborted block delivery, got \(first)")
            return
        }
        #expect(try journal.managedBlockLastPostedHash(issueID: "issue-1") == nil)

        let second = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        guard case .posted = second else {
            Issue.record("expected the rewrite to be attempted again, got \(second)")
            return
        }
    }

    // MARK: - Labels

    @Test("Disposition labels: one Block Reason at a time, one card type, and none once the Card is re-readied")
    func labelGroupExclusivity() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        await board.label(issue, add: labels.blockReason[.blockedByReviewer]!)
        await board.label(issue, add: labels.cardType[.featureCard]!)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        try setCard(journal, cardID, state: .blocked, blockReason: BlockReason.blockedByCheck.rawValue)
        let outbox = try heldOutbox(journal, board: board, cardID: cardID)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: labels)

        _ = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        let blocked = try #require(await board.issue(issue)?.labels)
        #expect(blocked == [labels.cardType[.workCard]!, labels.blockReason[.blockedByCheck]!])
        let description = try #require(await board.issue(issue)?.description)
        #expect(description.contains("**State:** Blocked — blocked by check"))

        try setCard(journal, cardID, state: .todo, blockReason: nil)
        _ = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        let readied = try #require(await board.issue(issue)?.labels)
        #expect(readied == [labels.cardType[.workCard]!])
    }

    @Test("Without a label catalogue only the block is written")
    func noLabelsMeansBlockOnly() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        await board.seed(issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try heldOutbox(journal, board: board, cardID: cardID)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: nil)

        _ = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)
        let operations = try journal.read { db in
            try String.fetchAll(db, sql: "SELECT operation FROM outbox WHERE issue_id = ?", arguments: ["issue-1"])
        }
        #expect(operations == ["descriptionRewrite"])
    }

    // MARK: - Cancelled

    @Test("Nothing is posted to a Cancelled Card, and a write already pending for it is aborted")
    func cancelledCardIsNotMaintained() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try heldOutbox(journal, board: board, cardID: cardID)
        let earlier = try outbox.accept(OutboxWrite(
            key: "comment:issue-1:earlier", write: .createComment(issue: issue, body: "from before"), cardID: cardID
        ))
        try setCard(journal, cardID, state: .cancelled, blockReason: nil)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: labels)

        let outcome = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)

        #expect(outcome == .notMaintained(.cancelled))
        #expect(await board.updateCalls == 0)
        #expect(await board.descriptionReads == 0)
        #expect(await board.comments.isEmpty)
        #expect(try journal.events(ofType: .managedBlockWritten).isEmpty)
        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(try journal.outboxEntry(id: earlier.id)?.state == .aborted)
    }

    // MARK: - Fixtures

    /// A run holding the Project's Act-scoped Lease and the Card's Lease: what a build Act holds when it
    /// maintains the Card it is working.
    private func heldOutbox(
        _ journal: JournalStore, board: FakeWritingBoard, cardID: Int64, runID: RunID = RunID()
    ) throws -> Outbox {
        let outbox = try outbox(journal, board: board, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        return outbox
    }

    /// A label catalogue with an id for every child of both groups.
    var labels: DispositionLabels {
        DispositionLabels(
            cardType: Dictionary(uniqueKeysWithValues: CardType.allCases.map {
                ($0, BoardObjectID(rawValue: "label-type-\($0.rawValue)"))
            }),
            blockReason: Dictionary(uniqueKeysWithValues: BlockReason.allCases.map {
                ($0, BoardObjectID(rawValue: "label-reason-\($0.rawValue)"))
            })
        )
    }

    private func setCard(_ journal: JournalStore, _ cardID: Int64, state: CardState, blockReason: String?) throws {
        try journal.write { db in
            try db.execute(
                sql: "UPDATE card SET state = ?, block_reason = ? WHERE id = ?",
                arguments: [state.rawValue, blockReason, cardID]
            )
        }
    }
}
