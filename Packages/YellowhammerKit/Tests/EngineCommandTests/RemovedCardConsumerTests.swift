import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Testing

// board-projection/read-board-changes-by-delta, OQ142: a Work Card whose issue was trashed, or archived
// while it was in play, is set aside. The Delta Read records it (DeltaReadRemovedCardTests.swift); these
// are the consumers that must then leave it alone — no dispatch, nothing posted to it, out of the
// Roll-up. `OutboxJournalFixture` is created inside every @Test, never in a helper.

/// Marks the Card removed directly, as the Delta Read's `markCardRemovedFromBoard` leaves it.
private func markRemoved(_ journal: JournalStore, cardID: Int64, how: CardRemoval = .trashed) throws {
    try journal.write { db in
        try db.execute(
            sql: "UPDATE card SET removed_from_board = ? WHERE id = ?", arguments: [how.rawValue, cardID]
        )
    }
}

@Suite("Consumers set a removed Work Card aside (OQ142)")
struct RemovedCardConsumerTests {
    let brief = ArchitecturalBrief(prose: "Add the endpoint.", transcriptions: [])

    @Test("A removed Todo Card is not runnable in its lane")
    func removedTodoIsNotRunnable() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let kept = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let removed = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .todo
        )
        try markRemoved(journal, cardID: removed, how: .archived)

        let lane = try #require(RepoLane.derive(from: try journal.cards(cycleID: cycleID)).first)
        #expect(lane.cards.count == 2)
        #expect(lane.runnable.map(\.id) == [kept])
    }

    @Test("Nothing is posted to a removed Card, and a write already pending for it is aborted")
    func removedCardIsNotMaintained() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let runID = RunID()
        let outbox = try outbox(journal, board: board, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let earlier = try outbox.accept(OutboxWrite(
            key: "comment:issue-1:earlier", write: .createComment(issue: issue, body: "from before"), cardID: cardID
        ))
        try markRemoved(journal, cardID: cardID)
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox, labels: nil)

        let outcome = try await maintenance.maintain(card: try journal.card(id: cardID), brief: brief)

        #expect(outcome == .notMaintained(.removedFromBoard))
        #expect(await board.updateCalls == 0)
        #expect(await board.descriptionReads == 0)
        #expect(await board.comments.isEmpty)
        #expect(try journal.events(ofType: .managedBlockWritten).isEmpty)
        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(try journal.outboxEntry(id: earlier.id)?.state == .aborted)
    }

    @Test("The Outbox aborts a pending write for a removed Card's issue instead of sending it")
    func outboxAbortsAWriteForARemovedCard() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let board = FakeWritingBoard()
        let issue = await board.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: board)
        try markRemoved(journal, cardID: cardID)

        let delivery = try await outbox.post(OutboxWrite(
            key: "comment:issue-1:later", write: .createComment(issue: issue, body: "too late")
        ))

        guard case .aborted(let reason) = delivery.outcome else {
            Issue.record("expected the write to be aborted, got \(delivery.outcome)")
            return
        }
        #expect(reason.contains("removed from the board"))
        #expect(delivery.entry.state == .aborted)
        #expect(await board.comments.isEmpty)
        #expect(await board.updateCalls == 0)
        #expect(try journal.pendingOutboxEntries().isEmpty)
    }

    @Test("The Roll-up omits a removed member, from its lane and from the Shelved group alike")
    func rollUpOmitsARemovedMember() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
        )
        let removedTodo = try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-2", repository: "backend", order: 2, state: .todo)
        )
        let removedShelved = try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-3", repository: "backend", order: 3, state: .shelved)
        )
        try markRemoved(journal, cardID: removedTodo)
        try markRemoved(journal, cardID: removedShelved, how: .archived)
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))

        _ = try await FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)
            .maintain(feature: feature, cycleID: cycleID)

        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(description.contains("BACK-1"))
        #expect(!description.contains("BACK-2"))
        #expect(!description.contains("BACK-3"))
        #expect(description.contains("1 of 1 Cards landed"))
        #expect(!description.contains("Shelved"))
        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        #expect(markers[removedShelved] == nil)
    }
}
