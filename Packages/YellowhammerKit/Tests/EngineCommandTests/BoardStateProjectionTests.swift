import Domain
import Foundation
import Testing

@testable import Engine
@testable import Journal

// board-projection (P5.8): a Card transition is written to the Journal and posted through the Outbox
// under a key derived from its own state_version; the workflow state and disposition labels move
// together; the Operator's board identity is assigned only entering Waiting on You and retained
// afterward on every other transition; Cancelled is refused (glossary → Cancelled: Yellowhammer reads
// it and never writes it); a crashed run's board projection is reposted from state_version and
// board_state_version alone, and a killed run's already-applied entry is recorded, not re-sent.

private let projectionOperator = BoardObjectID(rawValue: "operator-1")

private func makeProjectionBoards() async throws -> NightCardTestBoards {
    let boards = try await makeBoards()
    await boards.provisioning.seed(state: "In Progress", team: teamID, category: .started)
    await boards.provisioning.seed(state: "Blocked", team: teamID, category: .unstarted)
    await boards.provisioning.seed(state: "Waiting on You", team: teamID, category: .unstarted)
    return boards
}

@Suite("Board state projection")
struct BoardStateProjectionTests {
    // MARK: - A Card's lifecycle

    @Test("A Card's workflow state and labels move together through its lifecycle")
    func cardLifecycleMovesStateAndLabels() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        let issue = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        var record = try journal.card(id: cardID)

        // Todo → In Progress: the Card label, no Block Reason label.
        record = try await post(projection, &record, .inProgress)
        var issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.inProgress])
        #expect(issueState.labels == [boards.ids["Card"]!])

        // → Blocked(blockedByCheck): exactly that Block Reason label, assignee untouched.
        record = try await post(projection, &record, .blocked(.blockedByCheck))
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.blocked])
        #expect(issueState.labels == [boards.ids["Card"]!, boards.ids["blocked by check"]!])
        #expect(issueState.assignee == nil)

        // → ready again: the Block Reason label is gone.
        record = try await post(projection, &record, .ready)
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.todo])
        #expect(issueState.labels == [boards.ids["Card"]!])

        // → Waiting on You: workflow state and the assignee both move.
        record = try await post(projection, &record, .waitingOnYou(.question, operator: projectionOperator))
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.waitingOnYou])
        #expect(issueState.assignee == projectionOperator)

        // → Blocked(unanswered) from Waiting on You: the assignee is retained, nothing clears it.
        record = try await post(projection, &record, .blocked(.unanswered))
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.blocked])
        #expect(issueState.assignee == projectionOperator)
        #expect(issueState.labels == [boards.ids["Card"]!, boards.ids["unanswered"]!])

        // → Done: the Block Reason label clears again.
        record = try await post(projection, &record, .done)
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.done])
        #expect(issueState.labels == [boards.ids["Card"]!])
        #expect(record.stateVersion == 6)
    }

    @Test("Cancelled Card: the projection throws and nothing is posted")
    func cancelledCardThrowsAndPostsNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        let cancelled = try journal.markCardCancelled(
            cardID: cardID, runID: runID, act: .build, nightID: nil, now: outboxEpoch
        )

        await #expect(throws: JournalError.cardAlreadyCancelled(cardID: cardID)) {
            try await projection.transition(card: cancelled, to: .ready)
        }
        #expect(await boards.writing.updateCalls == 0)
    }

    // MARK: - The Feature Issue

    @Test("The Feature Issue's workflow state and labels move: In Progress, Waiting on You, Done")
    func featureIssueTransitions() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        let issue = await boards.writing.seed(issue: "feature-1", description: nil)
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        _ = try await projection.transition(featureIssue: issue, to: .inProgress)
        var issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.inProgress])
        #expect(issueState.labels.contains(boards.ids["Feature"]!))
        #expect(!issueState.labels.contains(boards.ids["Card"]!))

        _ = try await projection.transition(featureIssue: issue, to: .waitingOnYou, operator: projectionOperator)
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.waitingOnYou])
        #expect(issueState.assignee == projectionOperator)

        _ = try await projection.transition(featureIssue: issue, to: .done)
        issueState = try #require(await boards.writing.issue(issue))
        #expect(issueState.workflowState == scope.states[.done])
    }

    @Test("Cancelled is refused for the Feature Issue")
    func cancelledRefusedForFeatureIssue() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        let issue = await boards.writing.seed(issue: "feature-1", description: nil)
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        await #expect(throws: BoardStateScopeError.cancelledIsNeverWritten) {
            try await projection.transition(featureIssue: issue, to: .cancelled)
        }
    }

    // MARK: - Repost after a crash

    @Test("repost lands exactly one write after a simulated crash and records the board version")
    func repostAfterCrashLandsOneWrite() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        _ = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        // The Journal transition landed; the process died before the board write.
        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: outboxEpoch
        )

        let firstRepost = try await projection.repost()
        #expect(firstRepost.count == 1)
        guard case .posted(let record, _) = firstRepost[0] else {
            Issue.record("expected posted, got \(firstRepost[0])")
            return
        }
        #expect(record.stateVersion == 1)
        #expect(await boards.writing.updateCalls == 1)
        #expect(try journal.card(id: cardID).boardStateVersion == 1)

        let secondRepost = try await projection.repost()
        #expect(secondRepost.isEmpty)
        #expect(await boards.writing.updateCalls == 1)
    }

    @Test("repost records a killed run's already-applied entry without a second update call")
    func repostRecordsAlreadyAppliedEntry() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let runID = RunID()
        let issue = await boards.writing.seed(issue: "issue-1", description: nil)
        let cardID = try insertFixtureCard(journal, issueID: "issue-1")
        let outbox = try outbox(journal, board: boards.writing, runID: runID)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: outboxEpoch)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        _ = try journal.transitionCard(
            cardID: cardID, to: .inProgress, runID: runID, act: .build, nightID: nil, now: outboxEpoch
        )
        // The killed run reached the board and applied the write, but died before recording it.
        let key = BoardStateProjection.stateKey(issueID: "issue-1", version: 1)
        let change = BoardIssueChange(workflowState: scope.states[.inProgress])
        _ = try outbox.accept(OutboxWrite(
            key: key, write: .updateIssue(issue: issue, change: change, undo: nil), cardID: cardID
        ))
        _ = try await outbox.deliverPending()
        #expect(try journal.card(id: cardID).boardStateVersion == nil)
        let updatesBeforeRepost = await boards.writing.updateCalls

        let outcomes = try await projection.repost()

        #expect(outcomes.count == 1)
        guard case .posted = outcomes[0] else {
            Issue.record("expected posted, got \(outcomes[0])")
            return
        }
        #expect(await boards.writing.updateCalls == updatesBeforeRepost)
        #expect(try journal.card(id: cardID).boardStateVersion == 1)
    }

    // MARK: - Helpers

    @discardableResult
    private func post(
        _ projection: BoardStateProjection, _ record: inout CardRecord, _ transition: CardTransition
    ) async throws -> CardRecord {
        let outcome = try await projection.transition(card: record, to: transition)
        guard case .posted(let updated, _) = outcome else {
            Issue.record("expected posted, got \(outcome)")
            return record
        }
        return updated
    }
}
