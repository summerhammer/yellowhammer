import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

private func observeFeature(
    _ journal: JournalStore, runID: RunID, state: BoardWorkflowState, revision: TimeInterval,
    issueID: String = "FEAT-1", prune: Bool = false
) throws {
    let value = object(issueID, state: state, updatedAt: revision)
    let data = try JSONEncoder().encode(value)
    let payload = try #require(String(bytes: data, encoding: .utf8))
    try journal.recordBoardRead(BoardReadRecord(
        issuesSynced: nil, commentsSynced: nil,
        issues: [BoardIssueObservation(issueID: issueID, updatedAt: value.updatedAt, payload: payload)],
        comments: [], leavesBuildPending: false, clearsBuildPending: false,
        forgetsBefore: prune ? .distantFuture : nil
    ), runID: runID, now: outboxEpoch)
}

@Suite("Durable native cancellation of unmerged Features")
struct FeatureCancellationTests {
    @Test("Feature status survives footprint pruning and reopen; equal and older observations are immutable")
    func durableMonotonicStatus() throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend"], landed: true
        )
        try observeFeature(journal, runID: world.runID, state: stateCanceledByCategory, revision: 20, prune: true)
        try observeFeature(journal, runID: world.runID, state: stateTodo, revision: 20)
        try observeFeature(journal, runID: world.runID, state: stateTodo, revision: 10)
        try observeFeature(
            journal, runID: world.runID, state: stateCanceledByCategory, revision: 30, issueID: "unknown"
        )
        let reopened = try fixture.open()
        let held = try #require(try reopened.featureBoardObservation(issueID: "FEAT-1"))
        #expect(held.workflowState == stateCanceledByCategory)
        #expect(held.updatedAt == deltaEpoch.addingTimeInterval(20))
        #expect(try reopened.featureBoardObservation(issueID: "unknown") == nil)
        try observeFeature(journal, runID: world.runID, state: stateTodo, revision: 20.0001)
        #expect(try reopened.featureBoardObservation(issueID: "FEAT-1")?.workflowState == stateTodo)
    }

    @Test("Delta intake recognizes archived Features, keeps unrelated issues unknown, and retains state on empty reads")
    func deltaTracksArchivedFeature() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend"], landed: true
        )
        let board = FakeReadingBoard([page(objects: [
            object("FEAT-1", state: stateCanceledByCategory), object("unrelated", state: stateCanceledByCategory)
        ])])
        let (read, runID) = try deltaRead(journal, board: board)
        guard case .read(let report) = try await read.perform() else {
            Issue.record("expected complete read")
            return
        }
        #expect(report.unknownObjects.map(\.id.rawValue) == ["unrelated"])
        let empty = DeltaRead(journal: journal, board: FakeReadingBoard([page()]), runID: runID,
                              act: .land, clock: { outboxEpoch }, horizon: { .distantFuture })
        _ = try await empty.perform()
        #expect(try journal.featureBoardObservation(issueID: "FEAT-1")?.workflowState.isShelved == true)
    }

    @Test("A refused read stores no partial Feature state; a request-cap checkpoint cannot authorize decisions",
           arguments: [false, true])
    func failedOrIncompleteIntake(checkpointed: Bool) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend"], landed: true
        )
        let first = page(objects: [object("FEAT-1", state: stateCanceledByCategory)],
                         nextObjectCursor: BoardCursor(rawValue: "more"))
        let board = FakeReadingBoard([first, .failure(.rateLimited(retryAfter: nil, budget: nil))])
        var (read, runID) = try deltaRead(journal, board: board)
        if checkpointed { read.requestLimit = 1 }
        guard case .degraded = try await read.perform() else {
            Issue.record("expected degraded read")
            return
        }
        #expect((try journal.featureBoardObservation(issueID: "FEAT-1") != nil) == checkpointed)
        #expect(try journal.boardSyncPoint()?.issuesSynced == nil)
        #expect((try journal.boardSyncPoint()?.pass != nil) == checkpointed)
        #expect(try BoardSyncDecisionBarrier.isHeld(journal: journal, runID: runID))
    }

    @Test("Status-only maintenance and quiet standing share the note, preserve U, and remove it on uncancellation",
          arguments: [BoardWorkflowStateCategory.unstarted, .completed, .started])
    func sharedRenderingAndMaintenance(restoredCategory: BoardWorkflowStateCategory) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend", "mobile"], landed: true
        )
        await world.board.seed(issue: "FEAT-1", description: fenced(block: "old", prose: "Human prose\n"))
        try observeFeature(journal, runID: world.runID, state: stateCanceledByCategory, revision: 20, prune: true)
        let maintenance = FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)
        try await maintenance.maintainAll(night: world.night)
        let posted = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(posted.hasPrefix("Human prose\n"))
        #expect(posted.contains(FeatureCancellationAnnotation.note))
        let lines = try NightSummary.unmergedStackLines(night: world.night, journal: journal)
        #expect(lines.count == 1 && lines[0].contains(FeatureCancellationAnnotation.note))
        #expect(lines[0].contains("0 of 2 Feature Branches merged"))
        #expect(try journal.effectiveBase(repository: "backend")?.featureID == featureID)
        try journal.recordLanding(featureID: featureID, repository: "backend", mainlineCommit: "a", evidence: .ancestry)
        #expect(try journal.unmergedFeatureStack().count == 1)
        #expect(try NightSummary.unmergedStackLines(night: world.night, journal: journal)[0]
            .contains("1 of 2 Feature Branches merged"))
        let restored = BoardWorkflowState(
            id: BoardObjectID(rawValue: "s-restored"), name: "Operator's state", category: restoredCategory
        )
        try observeFeature(journal, runID: world.runID, state: restored, revision: 21)
        try await maintenance.maintainAll(night: world.night)
        let updated = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(!updated.contains(FeatureCancellationAnnotation.note))
        let restoredLines = try NightSummary.unmergedStackLines(night: world.night, journal: journal)
        #expect(restoredLines.count == 1)
        #expect(!restoredLines[0].contains(FeatureCancellationAnnotation.note))
        #expect(try journal.unmergedFeatureStack().map(\.feature.id) == [featureID])
        #expect(try journal.effectiveBase(repository: "mobile")?.featureID == featureID)
        try observeFeature(journal, runID: world.runID, state: stateCanceledByCategory, revision: 22)
        try journal.recordLanding(featureID: featureID, repository: "mobile", mainlineCommit: "b", evidence: .ancestry)
        #expect(try journal.unmergedFeatureStack().isEmpty)
        #expect(try NightSummary.unmergedStackLines(night: world.night, journal: journal).isEmpty)
        let cycleID = try gateCycleID(journal, featureID: featureID)
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        #expect(try FeatureRollUpMaintenance.rollUp(feature: feature, cycleID: cycleID, journal: journal)
            .cancellationSuffix.isEmpty)
        #expect(try fixture.open().featureBoardObservation(issueID: "FEAT-1")?.workflowState.isShelved == true)
    }

    @Test("A canceled Feature outside U renders no note")
    func canceledOutsideStackRendersNoNote() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend"], landed: true, released: true
        )
        try observeFeature(journal, runID: world.runID, state: stateCanceledByCategory, revision: 20)
        #expect(try journal.unmergedFeatureStack().isEmpty)
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))
        let cycleID = try gateCycleID(journal, featureID: featureID)
        #expect(try FeatureRollUpMaintenance.rollUp(feature: feature, cycleID: cycleID, journal: journal)
            .cancellationSuffix.isEmpty)
        #expect(try NightSummary.unmergedStackLines(night: world.night, journal: journal).isEmpty)
    }

    @Test("Queued and new Feature state projections preserve canceled after partial and final merges")
    func stateWritesPreserveCancellation() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend", "mobile"], landed: true
        )
        let issue = BoardObjectID(rawValue: "FEAT-1")
        await world.board.seed(issue: "FEAT-1", description: fenced(block: "old"))
        await world.board.operatorMoves(issue, to: stateCanceledByCategory.id)
        let queued = try world.outbox.accept(OutboxWrite(
            key: "queued-before-cancellation", write: .updateIssue(
                issue: issue, change: BoardIssueChange(workflowState: stateTodo.id), undo: nil
            )
        ))
        try observeFeature(journal, runID: world.runID, state: stateCanceledByCategory, revision: 20)
        let replay = try await world.outbox.deliverPending()
        #expect(replay.deliveries.first?.entry.id == queued.id)
        let replayed = try #require(replay.deliveries.first)
        guard case .superseded = replayed.outcome else {
            Issue.record("expected stale workflow write to be superseded")
            return
        }
        let boards = try await makeProjectionBoards()
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let projection = BoardStateProjection(journal: journal, outbox: world.outbox, scope: scope)
        try journal.recordLanding(featureID: featureID, repository: "backend", mainlineCommit: "a", evidence: .ancestry)
        _ = try await projection.transition(featureIssue: issue, to: .done)
        #expect(await world.board.issue(issue)?.workflowState == stateCanceledByCategory.id)
        try journal.recordLanding(featureID: featureID, repository: "mobile", mainlineCommit: "b", evidence: .ancestry)
        let reopened = try fixture.open()
        let nextProjection = BoardStateProjection(journal: reopened, outbox: world.outbox, scope: scope)
        _ = try await nextProjection.transition(featureIssue: issue, to: .inProgress)
        #expect(await world.board.issue(issue)?.workflowState == stateCanceledByCategory.id)
        #expect(try reopened.landings(featureID: featureID).count == 2)
        #expect(try reopened.unmergedFeatureStack().isEmpty)
        #expect(try reopened.events(ofType: .boardWriteSuperseded).count == 1)
    }

    @Test("Largest maintained UTF-16 rendering reserves the full annotation")
    func budgetReservation() {
        let largest = FeatureRollUpBlock.largestRendering(of: [], repositories: ["backend"])
        #expect(largest.contains(FeatureCancellationAnnotation.note))
        let basic = FeatureRollUpBlock(rollUp: FeatureRollUp(
            members: [], lanesPushed: true, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 1), issueStanding: .authoring,
            cancellationSuffix: " " + FeatureCancellationAnnotation.note
        )).render()
        #expect(largest.utf16.count >= basic.utf16.count)
    }
}
