import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// The build Act's Worktree-reconciliation steps, split out of BuildActTests.swift to keep that file
// under the file length limit.

extension BuildActTests {
    @Test("Worktree reconciliation runs after the lease sweep and before the board repost")
    func worktreeReconciliationRunsBetweenSweepAndRepost() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo)
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/nonexistent-wt",
            runID: runID, now: buildActEpoch
        )

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let board = ActBoard(
            reading: FakeReadingBoard([page()]), writing: boards.writing, provisioning: boards.provisioning
        )
        let workspace = ReconcilerFakeWorkspace()

        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, board: board, workspace: workspace,
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        try await invocation.run()

        #expect(workspace.removeCalls == [
            ReconcilerFakeWorkspace.RemoveCall(id: WorktreeID(rawValue: "wt-1"), force: true)
        ])

        let events = try journal.events()
        let relevantTypes: Set<JournalEventType> = [.expiredCardLeasesSwept, .worktreeLost, .boardStateReposted]
        let order = events.filter { relevantTypes.contains($0.type) }.map(\.type)
        #expect(order == [.expiredCardLeasesSwept, .worktreeLost, .boardStateReposted])
        #expect(try journal.events(ofType: .actEnded).count == 1)
    }

    @Test("Held Worktrees with no recorded Feature Branch stop the Act")
    func heldWorktreeWithNoBranchStopsTheAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: buildActEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        // No branch recorded.
        _ = try insertReconcilerCycle(journal, featureID: featureID)
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: "/tmp/nonexistent-wt",
            runID: runID, now: buildActEpoch
        )

        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            // No Card is in this fixture Cycle, so the trigger needs forcing to reach the Act's work.
            trigger: .forced, runID: runID, workspace: ReconcilerFakeWorkspace(),
            work: BuildAct(cardRunner: RecordingCardRunner()).work
        )

        await #expect(throws: BuildActError.featureBranchUnrecorded(featureID: featureID)) {
            try await invocation.run()
        }
        #expect(try journal.events(ofType: .actIncomplete).count == 1)
    }
}
