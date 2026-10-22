import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

@Suite("Feature writes wait for completed Board reconciliation")
struct FeatureBoardSyncBarrierTests {
    @Test("A refused, checkpointed or halted read defers queued state writes without spending delivery attempts",
           arguments: ["refused", "checkpointed", "halted"])
    func incompleteReadDefersStateWrite(readState: String) async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        _ = try insertGateFeature(journal, issueID: "FEAT-1", branch: "yh-feature", repositories: ["backend"])
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let entry = try world.outbox.accept(OutboxWrite(
            key: "feature-state", write: .updateIssue(
                issue: BoardObjectID(rawValue: "FEAT-1"),
                change: BoardIssueChange(workflowState: BoardObjectID(rawValue: "done")), undo: nil
            )
        ))
        if readState == "checkpointed" {
            let pass = BoardReadPass(
                horizon: outboxEpoch, issues: BoardPassRoot(since: nil, after: "next"),
                comments: BoardPassRoot(since: nil, done: true)
            )
            try journal.recordBoardRead(BoardReadRecord(
                issuesSynced: nil, commentsSynced: nil, issues: [], comments: [],
                leavesBuildPending: false, clearsBuildPending: false, forgetsBefore: nil, pass: .set(pass)
            ), runID: world.runID, now: outboxEpoch)
        } else if readState == "halted" {
            try journal.append(.actIncomplete(reason: "Board unavailable during reconciliation"),
                               act: .build, runID: world.runID, nightID: world.night.id)
        } else {
            try journal.append(.rateBudgetExhausted(degradation: "the Delta Read was refused", installation: nil),
                               act: .build, runID: world.runID, nightID: world.night.id)
        }

        let deferred = try await world.outbox.deliverPending()
        #expect(deferred.deliveries.first?.outcome == .deferred(.boardSyncIncomplete))
        #expect(try journal.outboxEntry(id: entry.id)?.state == .pending)
        #expect(try journal.outboxEntry(id: entry.id)?.attemptCount == 0)
        #expect(await world.board.updateCalls == 0)

        // Neither an Act-end maintenance hook nor its flush may bypass the same barrier.
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: world.night.nightStart, journal: journal,
            trigger: .forced, runID: world.runID, work: { _ in }
        )
        try await invocation.maintainRollUps(night: world.night, outbox: world.outbox)
        #expect(await world.board.updateCalls == 0)
        #expect(try journal.managedBlockLastPostedHash(issueID: "FEAT-1") == nil)

        // A later successful sync clears the checkpoint and permits the still-pending write.
        try journal.recordBoardRead(BoardReadRecord(
            issuesSynced: nil, commentsSynced: nil, issues: [], comments: [],
            leavesBuildPending: false, clearsBuildPending: false, forgetsBefore: nil, pass: .clear
        ), runID: world.runID, now: outboxEpoch)
        try journal.append(.deltaReadCompleted(
            objects: 0, comments: 0, ownComments: 0, requests: 1, since: nil, syncPoint: nil
        ), act: .build, runID: world.runID, nightID: world.night.id)
        let delivered = try await world.outbox.deliverPending()
        #expect(delivered.deliveries.first?.outcome == .applied(nil))
        #expect(await world.board.updateCalls == 1)
    }
}
