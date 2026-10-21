import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection/write-board-updates-through-the-outbox, "Revalidate the originating condition before
// delivery" (roadmap P22.4): a state write records the board workflow state it was decided against, and
// immediately before delivery the issue is read again. A board a human has moved on from is not written over
// with the cached value — the entry is superseded and the Delta Read recomputes from what the board holds.
//
// Residual race, asserted nowhere because it cannot be: Linear has no compare-and-swap, so a human save
// between the pre-flight read and the mutation is still overwritten.

private let projectionOperator = BoardObjectID(rawValue: "operator-1")

/// A Card in the Journal, a fake board holding its issue, and the projection that writes its state through
/// an Outbox that reads the board back before it delivers.
private struct ConditionRig {
    let journal: JournalStore
    let boards: NightCardTestBoards
    let scope: BoardStateScope
    let issue: BoardObjectID
    let cardID: Int64
    let runID: RunID
    let reading: FakeReadingBoard
    let outbox: Outbox
    let projection: BoardStateProjection

    var todo: BoardWorkflowState { state(.todo, "Todo") }

    func state(_ card: CardState, _ name: String) -> BoardWorkflowState {
        BoardWorkflowState(id: scope.states[card] ?? BoardObjectID(rawValue: "missing"), name: name)
    }

    /// The issue as the board now shows it, for the pre-flight read and for the next Delta Read.
    func showOnBoard(_ state: BoardWorkflowState, description: String? = nil) async {
        await boards.writing.operatorMoves(issue, to: state.id)
        await reading.seed(issue: object(issue.rawValue, state: state, description: description, updatedAt: 50))
    }

    func card() throws -> CardRecord { try journal.card(id: cardID) }
}

private func makeConditionRig(
    _ journal: JournalStore, issueID: String = "issue-1", pages: [Result<BoardDelta, BoardError>] = []
) async throws -> ConditionRig {
    let boards = try await makeProjectionBoards()
    let scope = try await BoardStateScope.resolve(using: boards.provisioning)
    let runID = RunID()
    let issue = await boards.writing.seed(issue: issueID, description: nil)
    let cardID = try insertFixtureCard(journal, issueID: issueID)
    let reading = FakeReadingBoard(pages)
    let outbox = try outbox(journal, board: boards.writing, runID: runID, reading: reading)
    _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
    return ConditionRig(
        journal: journal, boards: boards, scope: scope, issue: issue, cardID: cardID, runID: runID,
        reading: reading, outbox: outbox,
        projection: BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
    )
}

/// Runs the Card to In Progress on the board, then leaves its Blocked write queued behind a rate limit: the
/// state a deferred write or a crashed Act leaves, with the Journal ahead of the board.
private func queueBlockedWrite(_ rig: ConditionRig) async throws {
    let started = try await rig.projection.transition(card: try rig.card(), to: .inProgress)
    guard case .posted = started else {
        Issue.record("expected the In Progress write to be posted, got \(started)")
        return
    }
    await rig.boards.writing.refuseNext(.rateLimited(retryAfter: nil, budget: nil))
    let blocked = try await rig.projection.transition(card: try rig.card(), to: .blocked(.checkFailure))
    guard case .deferred = blocked else {
        Issue.record("expected the Blocked write to be deferred, got \(blocked)")
        return
    }
}

@Suite("Conditioned Outbox writes")
struct ConditionedOutboxWriteTests {
    @Test("A queued Blocked write whose Card the Operator moved to Todo is superseded, and the Card re-readies")
    func operatorTodoSupersedesQueuedBlocked() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        try await queueBlockedWrite(rig)
        await rig.showOnBoard(rig.todo)

        let report = try await rig.outbox.deliverPending()

        let superseded = try #require(report.deliveries.first)
        guard case .superseded = superseded.outcome else {
            Issue.record("expected superseded, got \(superseded.outcome)")
            return
        }
        #expect(try journal.outboxEntry(id: superseded.entry.id)?.state == .superseded)
        // Only the In Progress write ever reached the board: the Operator's Todo was not written over.
        #expect(await rig.boards.writing.writes(to: rig.issue).count == 1)
        #expect(try journal.events(ofType: .boardWriteSuperseded).count == 1)
        // The Journal's record of it as posted is closed, so nothing reposts it over the Operator's move.
        #expect(try journal.cardsWithUnpostedState().isEmpty)

        // The Delta Read then reads the Operator's Todo as the Operator's, and the Card re-readies.
        let board = FakeReadingBoard([page(objects: [object("issue-1", state: rig.todo, updatedAt: 50)])])
        let read = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .build, horizon: { .distantFuture }
        )
        guard case .read(let delta) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(delta.reReadied.map(\.issueID) == ["issue-1"])
        #expect(try rig.card().state == .todo)
    }

    @Test("After the Operator's Todo is imported, the Card's next state write is not mistaken for stale")
    func dispatchAfterReReadyIsDelivered() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        // Blocked was applied before the Operator moved the Card back to Todo.
        try await rig.projection.transition(card: try rig.card(), to: .inProgress).expectPosted()
        try await rig.projection.transition(card: try rig.card(), to: .blocked(.checkFailure)).expectPosted()
        await rig.showOnBoard(rig.todo)

        // An author Act's read parks the Operator's Todo; the build Act's read imports it and forgets the
        // observation as older than its overlap, as the observation store does.
        let board = FakeReadingBoard([page(objects: [object("issue-1", state: rig.todo, updatedAt: 50)])])
        var author = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .author, horizon: { .distantFuture }
        )
        author.acceptsReReady = false
        _ = try await author.perform()
        let build = DeltaRead(
            journal: journal, board: FakeReadingBoard([page()]), runID: rig.runID, act: .build,
            horizon: { .distantFuture }
        )
        _ = try await build.perform()
        try journal.write { db in try db.execute(sql: "DELETE FROM board_issue_seen") }
        #expect(try rig.card().state == .todo)

        // Dispatch: the Card goes In Progress. Yellowhammer's last write said Blocked, but the Journal knows
        // the board holds Todo, and so does the board.
        let started = try await rig.projection.transition(card: try rig.card(), to: .inProgress)

        started.expectPosted()
        let issue = try #require(await rig.boards.writing.issue(rig.issue))
        #expect(issue.workflowState == rig.scope.states[.inProgress])
    }

    @Test("A crash-recovery repost after the Operator Shelved the Card is superseded, and the Card is Shelved")
    func crashReplayAfterShelveIsSuperseded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        try await queueBlockedWrite(rig)
        await rig.showOnBoard(stateCanceledByCategory)

        // The next Act reposts before it reads, as the build Act does.
        let outcomes = try await rig.projection.repost()

        #expect(outcomes.count == 1)
        guard case .superseded = try #require(outcomes.first) else {
            Issue.record("expected superseded, got \(outcomes)")
            return
        }
        #expect(await rig.boards.writing.writes(to: rig.issue).count == 1)

        let board = FakeReadingBoard([page(objects: [
            object("issue-1", state: stateCanceledByCategory, updatedAt: 50)
        ])])
        let read = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .build, horizon: { .distantFuture }
        )
        guard case .read(let delta) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(delta.shelved.map(\.issueID) == ["issue-1"])
        #expect(try rig.card().state == .shelved)
    }

    @Test("A read that finds the Operator's move supersedes the queued write instead of hiding behind it")
    func deltaReadSupersedesInsteadOfHiding() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        try await queueBlockedWrite(rig)
        let pending = try journal.pendingOutboxEntries()
        #expect(pending.count == 1)

        // An author Act's read: it applies no re-ready, but it must not leave the stale write queued either.
        let board = FakeReadingBoard([page(objects: [object("issue-1", state: rig.todo, updatedAt: 50)])])
        var read = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .author, horizon: { .distantFuture }
        )
        read.acceptsReReady = false
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(try journal.pendingOutboxEntries().isEmpty)
        #expect(try journal.outboxEntry(id: try #require(pending.first).id)?.state == .superseded)
        #expect(report.reReadied.isEmpty)
        // Nothing replays the Journal's Blocked over the Operator's Todo before the build Act re-readies it.
        let outcomes = try await rig.projection.repost()
        #expect(outcomes.isEmpty)
        #expect(await rig.boards.writing.writes(to: rig.issue).count == 1)
    }

    @Test("A pending comment does not hide the Operator's move to Todo")
    func pendingCommentDoesNotHide() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        _ = try journal.transitionCard(
            cardID: rig.cardID, to: .blocked, blockReason: .checkFailure, runID: rig.runID, act: .build,
            nightID: nil, now: outboxEpoch
        )
        _ = try rig.outbox.accept(OutboxWrite(
            key: "comment:issue-1:1", write: .createComment(issue: rig.issue, body: "A note."), cardID: rig.cardID
        ))

        let board = FakeReadingBoard([page(objects: [object("issue-1", state: rig.todo, updatedAt: 50)])])
        let read = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .build, horizon: { .distantFuture }
        )
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(report.reReadied.map(\.issueID) == ["issue-1"])
        #expect(try journal.pendingOutboxEntries().count == 1)
    }

    @Test("A write of Yellowhammer's own still in flight is not read as the Operator's move")
    func inFlightWriteIsNotAHumanSignal() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        try await queueBlockedWrite(rig)

        // The board still holds the state the pending write was decided against.
        let inProgress = rig.state(.inProgress, "In Progress")
        let board = FakeReadingBoard([page(objects: [object("issue-1", state: inProgress, updatedAt: 50)])])
        let read = DeltaRead(
            journal: journal, board: board, runID: rig.runID, act: .build, horizon: { .distantFuture }
        )
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected a read")
            return
        }

        #expect(try journal.pendingOutboxEntries().count == 1)
        #expect(report.restated.isEmpty)
    }

    @Test("A Waiting on You expiry write after the Operator answered and moved the Feature is superseded")
    func expiryAfterAnswerIsSuperseded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        let feature = await rig.boards.writing.seed(issue: "feature-1", description: nil)
        try await rig.projection.transition(featureIssue: feature, to: .waitingOnYou, operator: projectionOperator)
        // The Operator answered the question and moved the Feature on.
        let started = rig.state(.inProgress, "In Progress")
        await rig.boards.writing.operatorMoves(feature, to: started.id)
        await rig.reading.seed(issue: object("feature-1", state: started, updatedAt: 50))

        // The write the unanswered-position clock queues when the position expires.
        var change = rig.scope.labels.change(cardType: .featureCard)
        change.workflowState = try rig.scope.id(for: .blocked)
        let delivery = try await rig.outbox.post(OutboxWrite(
            key: "feature:FEAT-1:refusal:1:expired", write: .updateIssue(issue: feature, change: change, undo: nil)
        ))

        guard case .superseded = delivery.outcome else {
            Issue.record("expected superseded, got \(delivery.outcome)")
            return
        }
        let issue = try #require(await rig.boards.writing.issue(feature))
        #expect(issue.workflowState == started.id)
    }

    @Test("A write whose board still holds its condition is delivered")
    func unchangedBoardDelivers() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        await rig.showOnBoard(rig.todo)
        try await rig.projection.transition(card: try rig.card(), to: .inProgress).expectPosted()
        await rig.reading.seed(issue: object("issue-1", state: rig.state(.inProgress, "In Progress"), updatedAt: 60))

        let blocked = try await rig.projection.transition(card: try rig.card(), to: .blocked(.checkFailure))

        blocked.expectPosted()
        let issue = try #require(await rig.boards.writing.issue(rig.issue))
        #expect(issue.workflowState == rig.scope.states[.blocked])
        #expect(try journal.events(ofType: .boardWriteSuperseded).isEmpty)
    }

    @Test("A board already at the write's own target is delivered, not superseded: a replay after a lost response")
    func boardAtTargetIsNotSuperseded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        try await queueBlockedWrite(rig)
        // The board applied the Blocked write but the response was lost: it already holds the target.
        await rig.showOnBoard(rig.state(.blocked, "Blocked"))

        let report = try await rig.outbox.deliverPending()

        let delivery = try #require(report.deliveries.first)
        guard case .applied = delivery.outcome else {
            Issue.record("expected applied, got \(delivery.outcome)")
            return
        }
        #expect(try journal.events(ofType: .boardWriteSuperseded).isEmpty)
    }

    @Test("A comment and a create are never superseded, whatever state the Operator moved the issue to")
    func commentsAndCreatesAreNeverConditioned() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        try await rig.projection.transition(card: try rig.card(), to: .inProgress).expectPosted()
        await rig.showOnBoard(rig.todo)

        let comment = try await rig.outbox.post(OutboxWrite(
            key: "comment:issue-1:1", write: .createComment(issue: rig.issue, body: "A note."), cardID: rig.cardID
        ))

        guard case .applied = comment.outcome else {
            Issue.record("expected the comment to be applied, got \(comment.outcome)")
            return
        }
        #expect(await rig.boards.writing.comments.count == 1)
    }

    @Test("A compensation that undoes a rolled-back group is not conditioned")
    func compensationIsUnconditioned() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let rig = try await makeConditionRig(journal)
        await rig.showOnBoard(rig.todo)
        let entry = try rig.outbox.accept(OutboxWrite(
            key: "rollback:g:1",
            write: .updateIssue(
                issue: rig.issue, change: BoardIssueChange(workflowState: rig.scope.states[.todo]), undo: nil
            ),
            revalidates: false
        ))

        #expect(entry.expectedStateID == nil)
    }
}

private extension BoardStateProjection.Outcome {
    @discardableResult
    func expectPosted() -> Bool {
        if case .posted = self { return true }
        Issue.record("expected posted, got \(self)")
        return false
    }
}
