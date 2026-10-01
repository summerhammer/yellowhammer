import Darwin
import Domain
@testable import Engine
import Foundation
import Journal
import ProcessTestSupport
import Repositories
import Testing

// Continues WorktreeReconcilerTests.swift, split out to keep that file under the length limit. Shares
// its fixtures (ReconcilerJournalFixture, ReconcilerFakeWorkspace, reconcilerBranch and the insert*/init*/
// make* helpers), all declared there without `private` for that reason.

@Suite("WorktreeReconciler, continued")
struct WorktreeReconcilerContinuedTests {

    @Test("Process fencing runs before the WIP commit: a holding process is killed and the commit still happens")
    func fencesBeforeCommitting() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "fence")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit
        )

        let process = try makeReconcilerSleepProcess(currentDirectory: worktree)
        defer { process.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let workspace = ReconcilerFakeWorkspace()
        let fencer = ProcessFencer(pollInterval: .milliseconds(20), quiescenceTimeout: .seconds(5))
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git,
            fencer: fencer
        )

        let result = try await reconciler.reconcile(featureID: featureID, branch: reconcilerBranch)

        let status = await process.waitForExit(timeout: .seconds(5))
        #expect(status == .signalled(SIGKILL) || status == .alreadyReaped)

        let fencedEvents = try journal.events(ofType: .worktreeFenced)
        #expect(fencedEvents.count == 1)
        guard case .worktreeFenced(_, _, _, let killed) = fencedEvents[0].event else {
            Issue.record("wrong event type")
            return
        }
        #expect(killed >= 1)

        guard case .wipCommitted = result["backend"] else {
            Issue.record("expected .wipCommitted, got \(String(describing: result["backend"]))")
            return
        }
    }

    @Test("Clean worktree: outcome .clean, no worktree events, no git objects created")
    func cleanWorktreeStaysClean() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "clean")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit
        )
        let before = await reconcilerObjectCount(in: worktree, git: git)

        let workspace = ReconcilerFakeWorkspace()
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git
        )
        let result = try await reconciler.reconcile(featureID: featureID, branch: reconcilerBranch)

        guard case .clean = result["backend"] else {
            Issue.record("expected .clean, got \(String(describing: result["backend"]))")
            return
        }
        await #expect(before == reconcilerObjectCount(in: worktree, git: git))

        let worktreeEventTypes: Set<JournalEventType> = [
            .worktreeLost, .worktreeFenced, .worktreeNotQuiescent, .worktreeWIPCommitted,
            .worktreeReconciliationFailed
        ]
        let events = try journal.events()
        #expect(events.allSatisfy { !worktreeEventTypes.contains($0.type) })
    }

    @Test("A released Worktree record is not swept")
    func releasedRecordIsNotSwept() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "released")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (worktree, _) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        let recorded = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID
        )
        _ = try journal.recordWorktreePush(id: recorded.id, commit: "deadbeef", runID: runID)
        _ = try journal.releaseWorktree(id: recorded.id, runID: runID)
        try FileManager.default.removeItem(at: worktree)

        let workspace = ReconcilerFakeWorkspace()
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git
        )
        let result = try await reconciler.reconcile(featureID: featureID, branch: reconcilerBranch)

        #expect(result.outcomes.isEmpty)
        #expect(workspace.removeCalls.isEmpty)
    }

    @Test("No known-good commit recorded: a dirty Worktree WIP-commits and stays at the WIP commit, with no reset")
    func knownGoodUnknownNoReset() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "nogood")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (worktree, _) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID
        )

        let workspace = ReconcilerFakeWorkspace()
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git
        )
        let result = try await reconciler.reconcile(featureID: featureID, branch: reconcilerBranch)

        guard case .wipCommitted(_, let wipCommit, _, let resetTo) = result["backend"] else {
            Issue.record("expected .wipCommitted, got \(String(describing: result["backend"]))")
            return
        }
        #expect(resetTo == nil)
        await #expect(reconcilerRevParse("HEAD", in: worktree, git: git) == wipCommit)
    }

    @Test("Reconciling a dirty Worktree twice writes no second WIP commit and no second event")
    func idempotentReconciliation() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "idempotent")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: reconcilerBranch.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit
        )

        let workspace = ReconcilerFakeWorkspace()
        let reconciler = WorktreeReconciler(
            workspace: workspace, journal: journal, runID: runID, act: .build, nightID: nil, git: git
        )

        let firstResult = try await reconciler.reconcile(featureID: featureID, branch: reconcilerBranch)
        try #require(isWIPCommitted(firstResult["backend"]))
        let countAfterFirst = await reconcilerBranchCommitCount(worktree: worktree, git: git)

        let secondResult = try await reconciler.reconcile(featureID: featureID, branch: reconcilerBranch)
        guard case .clean = secondResult["backend"] else {
            Issue.record("expected .clean on the second reconcile, got \(String(describing: secondResult["backend"]))")
            return
        }
        let countAfterSecond = await reconcilerBranchCommitCount(worktree: worktree, git: git)
        #expect(countAfterFirst == countAfterSecond)

        let wipRef = "refs/yellowhammer/wip/\(reconcilerBranch.name)"
        let log = await git.run(["log", "--format=%s", wipRef], workingDirectory: worktree.path).stdout
        let wipSubjects = log.split(separator: "\n").filter { $0.hasPrefix("chore(wip): preserve uncommitted work on") }
        #expect(wipSubjects.count == 1)
        let wipBody = await git.run(
            ["log", "-1", "--format=%B%an <%ae>", wipRef], workingDirectory: worktree.path
        ).stdout
        #expect(wipBody.contains("Yellowhammer-WIP: \(reconcilerBranch.name)"))
        #expect(wipBody.contains("Yellowhammer <noreply@yellowhammer.dev>"))

        #expect(try journal.events(ofType: .worktreeWIPCommitted).count == 1)
    }

    private func isWIPCommitted(_ outcome: WorktreeReconciliationOutcome?) -> Bool {
        guard case .wipCommitted = outcome else { return false }
        return true
    }

    private func reconcilerBranchCommitCount(worktree: URL, git: GitRunner) async -> String {
        await git.run(["rev-list", "--count", reconcilerBranch.name], workingDirectory: worktree.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
