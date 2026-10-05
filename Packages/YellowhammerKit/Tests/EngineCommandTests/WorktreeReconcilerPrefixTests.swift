import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// Reconciliation WIP-commits on the Feature Branch recorded for the Worktree, which Orca ADE may have
// reported with a `<prefix>/` before the requested Worktree name. Split out of WorktreeReconcilerTests.swift
// to keep it short.

@Suite("WorktreeReconciler recorded Feature Branch")
struct WorktreeReconcilerPrefixTests {
    @Test("A recorded prefixed Feature Branch carries the WIP commit; no unprefixed ref is created")
    func wipCommitUsesRecordedPrefixedBranch() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimReconcilerLease(journal, runID: runID)
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        _ = try insertReconcilerCycle(journal, featureID: featureID)

        let git = GitRunner()
        let tempDir = try makeReconcilerTempDir(name: "prefixed")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let prefixed = FeatureBranch(name: "rozd/\(reconcilerBranch.name)")
        let (worktree, baseCommit) = try await makeReconcilerRepoAndWorktree(
            named: "backend", branch: prefixed.name, in: tempDir, git: git
        )
        try "modified".write(to: worktree.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        _ = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend", path: worktree.path,
            runID: runID, lastKnownGoodCommit: baseCommit, featureBranch: prefixed
        )

        let reconciler = WorktreeReconciler(
            workspace: ReconcilerFakeWorkspace(), journal: journal, runID: runID, act: .build, nightID: nil,
            git: git
        )
        let result = try await reconciler.reconcile(feature: try #require(journal.feature(id: featureID)))

        guard case .wipCommitted(_, let wipCommit, let wipRef, _) = result["backend"] else {
            Issue.record("expected .wipCommitted, got \(String(describing: result["backend"]))")
            return
        }
        #expect(wipRef == "refs/yellowhammer/wip/\(prefixed.name)")
        await #expect(reconcilerRevParse(wipRef, in: worktree, git: git) == wipCommit)
        await #expect(reconcilerRevParse("refs/heads/\(prefixed.name)", in: worktree, git: git) == baseCommit)

        let unprefixedBranch = await git.run(
            ["rev-parse", "--verify", "--quiet", "refs/heads/\(reconcilerBranch.name)"],
            workingDirectory: worktree.path
        )
        #expect(unprefixedBranch.exitCode != 0)
        let unprefixedWIP = await git.run(
            ["rev-parse", "--verify", "--quiet", "refs/yellowhammer/wip/\(reconcilerBranch.name)"],
            workingDirectory: worktree.path
        )
        #expect(unprefixedWIP.exitCode != 0)
    }
}
