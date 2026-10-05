import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import GRDB
@testable import Journal
import Testing

// A ghost Worktree whose Feature Branch pin could not be written stays HELD with a missing path (OQ123).
// The build Act must not reuse it: it would dispatch a Card into a nonexistent directory and spend an
// Attempt. `WorktreeReconciliation.isDispatchable` documents that rule; the lane pre-pass now applies it.

extension BuildActTests {
    @Test("A kept ghost Worktree runs no Card and spends no Attempt")
    func keptGhostRunsNoCardAndSpendsNoAttempt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)
        // A ghost: the recorded path does not exist, and no repository is configured to pin its branch in.
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/nonexistent-ghost-wt",
            runID: runID, now: buildActEpoch, featureBranch: buildActBranch
        )

        let recorder = RecordingCardRunner()
        let workspace = ReconcilerFakeWorkspace()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, workspace: workspace,
            work: BuildAct(cardRunner: recorder).work
        )

        do {
            try await invocation.run()
            Issue.record("expected the Act to throw lanesFailed")
        } catch let BuildActError.lanesFailed(failures) {
            #expect(failures.keys.sorted() == ["backend"])
            #expect(failures["backend"]?.contains("did not settle") == true)
        } catch {
            Issue.record("expected BuildActError.lanesFailed, got \(error)")
        }

        #expect(recorder.seen.isEmpty)
        #expect(try journal.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attempt") } == 0)
        #expect(workspace.removeCalls.isEmpty)
        // The kept ghost (not some other reconciliation failure) is what stopped the lane.
        #expect(try journal.events(ofType: .worktreeReconciliationFailed).count == 1)
        #expect(try journal.events(ofType: .worktreeLost).isEmpty)
        #expect(try journal.heldWorktree(featureID: featureID, repository: "backend") != nil)
    }
}
