import Domain
import Foundation
import Repositories
import Testing

// A new Attempt starts fresh, never as a rescue (Attempt, Block and Reset Ruling 2026-09-19, OQ60):
// commits + dirty tree preserve one WIP commit under the Attempt's ref, then reset to known-good.

@Suite("WorktreeCommitter, Attempt preservation")
struct WorktreeCommitterPreservationTests {
    @Test("Commits plus a dirty tree preserve one WIP commit under the Attempt's ref, then reset to known-good")
    func dirtyTreePreservesAndResets() async throws {
        let fixture = GitFixture(name: "preserve-dirty-1")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        try fixture.writeFile(filename: "feat.txt", content: "dirty attempt edit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: 41, knownGood: knownGood
        )

        guard case .reset(let ref, let commit, let resetTo) = outcome else {
            Issue.record("expected .reset, got \(outcome)")
            return
        }
        #expect(ref == "refs/yellowhammer/attempts/yh-project-feature/41")
        #expect(resetTo == knownGood)
        #expect(fixture.revParse(try #require(ref)) == commit)
        #expect(fixture.revParse("HEAD") == knownGood)
        #expect(fixture.run(["status", "--porcelain"]).stdout.isEmpty)
    }

    @Test("A second run is a no-op: no second WIP commit, and the ref is unchanged")
    func secondRunIsANoOp() async throws {
        let fixture = GitFixture(name: "preserve-idempotent-2")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        try fixture.writeFile(filename: "feat.txt", content: "dirty attempt edit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let first = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: 41, knownGood: knownGood
        )
        guard case .reset(let firstRef, let firstCommit, _) = first else {
            Issue.record("expected .reset, got \(first)")
            return
        }
        let countBefore = fixture.run(["rev-list", "--all", "--count"]).stdout

        let second = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: 41, knownGood: knownGood
        )
        guard case .reset(let secondRef, let secondCommit, let secondResetTo) = second else {
            Issue.record("expected .reset, got \(second)")
            return
        }

        #expect(secondRef == nil)
        #expect(secondCommit == nil)
        #expect(secondResetTo == knownGood)
        #expect(fixture.revParse(try #require(firstRef)) == firstCommit)
        #expect(fixture.run(["rev-list", "--all", "--count"]).stdout == countBefore)
    }

    @Test("The Feature Branch tip already at known-good: no ref, nothing preserved")
    func tipAlreadyKnownGoodPreservesNothing() async throws {
        let fixture = GitFixture(name: "preserve-clean-3")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: 41, knownGood: knownGood
        )

        guard case .reset(let ref, let commit, let resetTo) = outcome else {
            Issue.record("expected .reset, got \(outcome)")
            return
        }
        #expect(ref == nil)
        #expect(commit == nil)
        #expect(resetTo == knownGood)
    }

    @Test("A dirty Worktree off the Feature Branch is refused: nothing preserved, nothing reset")
    func dirtyOffBranchIsRefused() async throws {
        let fixture = GitFixture(name: "preserve-wrong-branch-4")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = fixture.run(["checkout", "main"])
        try fixture.writeFile(filename: "tracked.txt", content: "changed while on main")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: 41, knownGood: knownGood
        )

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(fixture.revParse("refs/yellowhammer/attempts/yh-project-feature/41") == nil)
    }

    @Test("No Attempt to attribute the work to: the WIP commit and reset still run, with no per-Attempt ref")
    func noAttemptIDStillResets() async throws {
        let fixture = GitFixture(name: "preserve-no-attempt-5")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        try fixture.writeFile(filename: "feat.txt", content: "dirty attempt edit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: nil, knownGood: knownGood
        )

        guard case .reset(let ref, let commit, let resetTo) = outcome else {
            Issue.record("expected .reset, got \(outcome)")
            return
        }
        #expect(ref == nil)
        #expect(commit == nil)
        #expect(resetTo == knownGood)
        #expect(fixture.revParse("HEAD") == knownGood)
    }
}
