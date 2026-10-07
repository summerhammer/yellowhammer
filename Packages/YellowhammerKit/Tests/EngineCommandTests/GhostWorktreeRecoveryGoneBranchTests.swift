import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// Issue #355, spec OQ133: the Operator removed the Worktree in Orca ADE, so directory AND Feature Branch
// are already gone when the ghost purge runs. The purge still proceeds — refusing would wedge the lane —
// but it first tries to pin the lane's `last_known_good_commit` (an unreachable commit survives until
// `git gc`), and when that object is gone too it records the loss for the Night Summary to name. Real git
// repository and the Orca ADE look-alike from GhostWorktreeRecoveryTests.

/// A lane whose only commit is a Done Card's: the Worktree is a ghost, its branch deleted behind
/// Yellowhammer's back, and the Journal's `last_known_good_commit` advanced to the Done Card's commit.
private struct GoneBranchLane {
    let scene: GhostScene
    let worktree: WorktreeRecord
    let branch: FeatureBranch
    /// The Done Card's commit, which is also the lane's `last_known_good_commit`.
    let tip: String
    let doneCard: Int64
}

private func makeGoneBranchLane(
    _ scene: GhostScene, pushed: Bool = false
) async throws -> GoneBranchLane {
    let first = try await scene.allocate()
    let branch = try scene.recordedBranch()
    let tip = try await scene.commitFile(in: first)
    var worktree = try scene.journal.recordWorktreeKnownGood(id: first.id, commit: tip, runID: scene.runID)
    if pushed {
        worktree = try scene.journal.recordWorktreePush(id: first.id, commit: tip, runID: scene.runID)
    }
    let doneCard = try insertReconcilerCard(
        scene.journal, cycleID: scene.cycleID, issueID: "CARD-1", repository: "backend", state: .done
    )
    // The Operator removed the Worktree in Orca ADE: directory and branch are both gone.
    try scene.removeDirectory(of: first)
    _ = await scene.git.run(["-C", scene.repository.path, "worktree", "prune"])
    _ = await scene.git.run(["-C", scene.repository.path, "branch", "-D", branch.name])
    #expect(await scene.tip(of: "refs/heads/\(branch.name)") == nil)
    return GoneBranchLane(scene: scene, worktree: worktree, branch: branch, tip: tip, doneCard: doneCard)
}

/// What `git gc` eventually does to a commit nothing reaches: drops it from the object store.
private func pruneUnreachable(_ scene: GhostScene) async {
    _ = await scene.git.run(["-C", scene.repository.path, "reflog", "expire", "--expire=now", "--all"])
    _ = await scene.git.run(["-C", scene.repository.path, "prune", "--expire=now"])
}

@Suite("Ghost Worktree recovery: the Feature Branch is already gone (OQ133)")
struct GhostWorktreeRecoveryGoneBranchTests {
    @Test("With the commit in the object store, the purge pins last_known_good_commit and re-allocation recovers it")
    func reachableCommitIsPinnedAndRecovered() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let lane = try await makeGoneBranchLane(scene)

        guard case .lost = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        #expect(await scene.tip(of: scene.pinRef(for: lane.branch)) == lane.tip)
        #expect(try scene.recoveryCommit() == lane.tip)
        let lostEvents = try scene.lostEvents()
        #expect(lostEvents.count == 1)
        guard case .worktreeLost(
            _, _, _, _, let pinnedCommit, let lostCommit, let lostDoneCardIDs
        ) = lostEvents[0] else {
            Issue.record("expected a worktreeLost event")
            return
        }
        #expect(pinnedCommit == lane.tip)
        #expect(lostCommit == nil)
        #expect(lostDoneCardIDs.isEmpty)
        #expect(try scene.journal.card(id: lane.doneCard).state == .done)

        let second = try await scene.allocate()
        #expect(scene.workspace.createCalls.last?.baseBranch == scene.pinRef(for: lane.branch))
        #expect(try scene.recordedBranch() == lane.branch)
        #expect(await scene.tip(of: "refs/heads/\(lane.branch.name)") == lane.tip)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: second.path)
            .appendingPathComponent("done-card.txt").path))
        #expect(second.lastKnownGoodCommit == lane.tip)
        #expect(await scene.tip(of: scene.pinRef(for: lane.branch)) == nil)
        #expect(try scene.recoveryCommit() == nil)
    }

    @Test("With the commit pruned too, the purge still proceeds and records the lost tip and the Done Cards")
    func prunedCommitIsRecordedAsLost() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let lane = try await makeGoneBranchLane(scene)
        await pruneUnreachable(scene)
        // Precondition: the commit really is gone, so this is not the reachable case in disguise.
        #expect(await scene.tip(of: lane.tip) == nil)

        guard case .lost(let lost) = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        #expect(lost.id == lane.worktree.id)
        #expect(scene.workspace.removeCalls.map(\.id) == [WorktreeID(rawValue: lane.worktree.worktreeID)])
        #expect(await scene.tip(of: scene.pinRef(for: lane.branch)) == nil)
        #expect(try scene.recoveryCommit() == nil)
        let lostEvents = try scene.lostEvents()
        #expect(lostEvents.count == 1)
        guard case .worktreeLost(
            _, _, _, _, let pinnedCommit, let lostCommit, let lostDoneCardIDs
        ) = lostEvents[0] else {
            Issue.record("expected a worktreeLost event")
            return
        }
        #expect(pinnedCommit == nil)
        #expect(lostCommit == lane.tip)
        #expect(lostDoneCardIDs == [lane.doneCard])

        _ = try await scene.allocate()
        #expect(scene.workspace.createCalls.last?.baseBranch == nil)
    }

    @Test("Work already pushed survives on the remote: nothing is recorded as lost")
    func pushedWorkIsNotNamedAsLost() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let lane = try await makeGoneBranchLane(scene, pushed: true)
        await pruneUnreachable(scene)
        #expect(await scene.tip(of: lane.tip) == nil)

        guard case .lost = try await scene.reconcile() else {
            Issue.record("expected the ghost Worktree to be purged as lost")
            return
        }
        guard case .worktreeLost(_, _, _, _, let pinnedCommit, let lostCommit, let lostDoneCardIDs) =
            try scene.lostEvents()[0]
        else {
            Issue.record("expected a worktreeLost event")
            return
        }
        #expect(pinnedCommit == nil)
        #expect(lostCommit == nil)
        #expect(lostDoneCardIDs.isEmpty)
    }

    @Test("A pin that cannot be written for last_known_good_commit still holds the Worktree")
    func unwritablePinHoldsTheGhost() async throws {
        let fixture = try ReconcilerJournalFixture()
        let scene = try await GhostScene(journal: try fixture.open())
        let lane = try await makeGoneBranchLane(scene)
        // A file where the pin ref's directory must go: git cannot create `refs/yellowhammer/recovery/...`.
        let blocked = scene.repository.appendingPathComponent(".git/refs/yellowhammer")
        try "not a directory".write(to: blocked, atomically: true, encoding: .utf8)

        let outcome = try await scene.reconcile()

        guard case .ghostKept(_, let reason) = outcome else {
            Issue.record("expected .ghostKept, got \(outcome)")
            return
        }
        #expect(reason.contains(scene.pinRef(for: lane.branch)))
        #expect(scene.workspace.removeCalls.isEmpty)
        let held = try scene.journal.heldWorktree(featureID: scene.featureID, repository: "backend")
        #expect(held?.id == lane.worktree.id)
        #expect(try scene.lostEvents().isEmpty)
        #expect(try scene.journal.card(id: lane.doneCard).state == .done)
    }
}
