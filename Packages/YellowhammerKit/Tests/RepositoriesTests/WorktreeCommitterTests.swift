import Domain
import Foundation
import Repositories
import Testing

@Suite("WIP commit tests")
struct WorktreeCommitterTests {

    @Test("A dirty Worktree with tracked and untracked changes is committed as one WIP commit")
    func dirtyWorktreeCommitsOnce() async throws {
        let fixture = GitFixture(name: "wip-dirty-1")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])

        try fixture.writeFile(filename: "tracked.txt", content: "changed")
        try fixture.writeFile(filename: "untracked.txt", content: "new file")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)

        guard case .committed(let commit, let wipRef) = outcome else {
            Issue.record("expected .committed, got \(outcome)")
            return
        }
        #expect(wipRef == "refs/yellowhammer/wip/yh-project-feature")
        await #expect(fixture.revParse(wipRef) == commit)
        await #expect(fixture.revParse("HEAD") == commit)

        let status = await fixture.run(["status", "--porcelain"]).stdout
        #expect(status.isEmpty)

        let message = await fixture.run(["log", "-1", "--format=%s"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(message.hasPrefix(WorktreeCommitter.messageMarker))
        #expect(message.contains("yh-project-feature"))
    }

    @Test("Committing WIP twice without new changes does not create a second commit")
    func idempotentAcrossCalls() async throws {
        let fixture = GitFixture(name: "wip-idempotent-2")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        try fixture.writeFile(filename: "tracked.txt", content: "changed")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let first = await committer.commitWIP(worktreePath: fixture.path, branch: branch)
        guard case .committed(let firstCommit, let wipRef) = first else {
            Issue.record("expected .committed, got \(first)")
            return
        }

        let countBefore = await fixture.run(["rev-list", "--count", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let second = await committer.commitWIP(worktreePath: fixture.path, branch: branch)
        guard case .noChanges(let headCommit, let secondWipRef, let wipCommit) = second else {
            Issue.record("expected .noChanges, got \(second)")
            return
        }
        #expect(headCommit == firstCommit)
        #expect(secondWipRef == wipRef)
        #expect(wipCommit == firstCommit)

        let countAfter = await fixture.run(["rev-list", "--count", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(countBefore == countAfter)
    }

    @Test("A clean Worktree with no standing WIP ref is a no-op that writes nothing")
    func cleanWorktreeIsNoOp() async throws {
        let fixture = GitFixture(name: "wip-clean-3")
        await fixture.initRepo(defaultBranch: "main")
        let headSHA = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)

        guard case .noChanges(let headCommit, let wipRef, let wipCommit) = outcome else {
            Issue.record("expected .noChanges, got \(outcome)")
            return
        }
        #expect(headCommit == headSHA)
        #expect(wipRef == nil)
        #expect(wipCommit == nil)
    }

    @Test("A Worktree not on its Feature Branch is refused, writing nothing")
    func notOnFeatureBranchIsRefused() async throws {
        let fixture = GitFixture(name: "wip-wrong-branch-4")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = await fixture.run(["checkout", "main"])
        try fixture.writeFile(filename: "tracked.txt", content: "changed while on main")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        await #expect(fixture.revParse("refs/yellowhammer/wip/yh-project-feature") == nil)
        let status = await fixture.run(["status", "--porcelain"]).stdout
        #expect(status.contains("tracked.txt"))
    }

    @Test("A missing Worktree path is refused, writing nothing")
    func missingWorktreeIsRefused() async throws {
        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.commitWIP(
            worktreePath: "/tmp/nonexistent-yellowhammer-worktree-\(UUID().uuidString)",
            branch: branch
        )

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
    }
}

// roadmap P8.11: a rehearsal Night never commits into a Worktree (system-overview, Environment
// Differences).
@Suite("Rehearsal WIP commit boundary tests")
struct WorktreeCommitterRehearsalTests {

    @Test("A dirty Worktree in rehearsal mode is refused, writing nothing and leaving changes in place")
    func dirtyWorktreeInRehearsalIsRefused() async throws {
        let fixture = GitFixture(name: "wip-rehearsal-dirty-1")
        await fixture.initRepo(defaultBranch: "main")
        let headSHA = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        try fixture.writeFile(filename: "tracked.txt", content: "changed")
        try fixture.writeFile(filename: "untracked.txt", content: "new file")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter(mode: .rehearsal)
        let outcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        await #expect(fixture.revParse("HEAD") == headSHA)
        await #expect(fixture.revParse("refs/yellowhammer/wip/yh-project-feature") == nil)
        let status = await fixture.run(["status", "--porcelain"]).stdout
        #expect(status.contains("tracked.txt"))
        #expect(status.contains("untracked.txt"))
    }

    @Test("A clean Worktree in rehearsal mode is still a no-op, exactly as in real mode")
    func cleanWorktreeInRehearsalIsNoOp() async throws {
        let fixture = GitFixture(name: "wip-rehearsal-clean-2")
        await fixture.initRepo(defaultBranch: "main")
        let headSHA = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter(mode: .rehearsal)
        let outcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)

        guard case .noChanges(let headCommit, let wipRef, let wipCommit) = outcome else {
            Issue.record("expected .noChanges, got \(outcome)")
            return
        }
        #expect(headCommit == headSHA)
        #expect(wipRef == nil)
        #expect(wipCommit == nil)
    }

    @Test("preserveAndReset in rehearsal mode refuses a dirty Worktree without committing")
    func preserveAndResetInRehearsalRefusesDirtyTree() async throws {
        let fixture = GitFixture(name: "wip-rehearsal-preserve-3")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        try fixture.writeFile(filename: "feat.txt", content: "dirty feature edit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter(mode: .rehearsal)
        let outcome = await committer.preserveAndReset(
            worktreePath: fixture.path, branch: branch, attemptID: 1, knownGood: knownGood
        )

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        // HEAD is unchanged: `knownGood` was already the tip before this call, and nothing was committed.
        await #expect(fixture.revParse("HEAD") == knownGood)
        let contents = try String(contentsOf: fixture.url.appending(component: "feat.txt"), encoding: .utf8)
        #expect(contents == "dirty feature edit")
    }
}

@Suite("Worktree reset-to-known-good tests")
struct WorktreeResetTests {

    @Test("Resetting after a WIP commit moves the Feature Branch to known-good and keeps the WIP ref reachable")
    func resetAfterWIPCommit() async throws {
        let fixture = GitFixture(name: "reset-after-wip-1")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        try fixture.writeFile(filename: "feat.txt", content: "dirty feature edit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let wipOutcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)
        guard case .committed(let wipCommit, _) = wipOutcome else {
            Issue.record("expected .committed, got \(wipOutcome)")
            return
        }

        let resetOutcome = await committer.resetToKnownGood(
            worktreePath: fixture.path,
            branch: branch,
            knownGood: knownGood
        )
        guard case .reset(let to, let wipRef) = resetOutcome else {
            Issue.record("expected .reset, got \(resetOutcome)")
            return
        }
        #expect(to == knownGood)
        #expect(wipRef == "refs/yellowhammer/wip/yh-project-feature")
        await #expect(fixture.revParse(try #require(wipRef)) == wipCommit)
        await #expect(fixture.revParse("HEAD") == knownGood)

        let status = await fixture.run(["status", "--porcelain"]).stdout
        #expect(status.isEmpty)
    }

    @Test("A dirty Worktree is refused and the uncommitted file is left untouched")
    func dirtyWorktreeIsRefused() async throws {
        let fixture = GitFixture(name: "reset-dirty-2")
        await fixture.initRepo(defaultBranch: "main")
        let knownGood = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        try fixture.writeFile(filename: "tracked.txt", content: "dirty edit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.resetToKnownGood(
            worktreePath: fixture.path,
            branch: branch,
            knownGood: knownGood
        )

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        let contents = try String(contentsOf: fixture.url.appending(component: "tracked.txt"), encoding: .utf8)
        #expect(contents == "dirty edit")
    }

    @Test("An unresolvable known-good commit is refused")
    func unresolvableKnownGoodIsRefused() async throws {
        let fixture = GitFixture(name: "reset-unresolvable-3")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.resetToKnownGood(
            worktreePath: fixture.path,
            branch: branch,
            knownGood: "0000000000000000000000000000000000000000"
        )

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
    }
}
