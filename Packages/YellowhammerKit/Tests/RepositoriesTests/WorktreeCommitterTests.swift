import Domain
import Foundation
import Repositories
import Testing

@Suite("WIP commit tests")
struct WorktreeCommitterTests {

    @Test("A dirty Worktree with tracked and untracked changes is committed as one WIP commit")
    func dirtyWorktreeCommitsOnce() async throws {
        let fixture = GitFixture(name: "wip-dirty-1")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])

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
        #expect(fixture.revParse(wipRef) == commit)
        #expect(fixture.revParse("HEAD") == commit)

        let status = fixture.run(["status", "--porcelain"]).stdout
        #expect(status.isEmpty)

        let message = fixture.run(["log", "-1", "--format=%s"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(message.hasPrefix(WorktreeCommitter.messageMarker))
        #expect(message.contains("yh-project-feature"))
    }

    @Test("Committing WIP twice without new changes does not create a second commit")
    func idempotentAcrossCalls() async throws {
        let fixture = GitFixture(name: "wip-idempotent-2")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        try fixture.writeFile(filename: "tracked.txt", content: "changed")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let first = await committer.commitWIP(worktreePath: fixture.path, branch: branch)
        guard case .committed(let firstCommit, let wipRef) = first else {
            Issue.record("expected .committed, got \(first)")
            return
        }

        let countBefore = fixture.run(["rev-list", "--count", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let second = await committer.commitWIP(worktreePath: fixture.path, branch: branch)
        guard case .noChanges(let headCommit, let secondWipRef, let wipCommit) = second else {
            Issue.record("expected .noChanges, got \(second)")
            return
        }
        #expect(headCommit == firstCommit)
        #expect(secondWipRef == wipRef)
        #expect(wipCommit == firstCommit)

        let countAfter = fixture.run(["rev-list", "--count", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(countBefore == countAfter)
    }

    @Test("A clean Worktree with no standing WIP ref is a no-op that writes nothing")
    func cleanWorktreeIsNoOp() async throws {
        let fixture = GitFixture(name: "wip-clean-3")
        fixture.initRepo(defaultBranch: "main")
        let headSHA = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])

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
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = fixture.run(["checkout", "main"])
        try fixture.writeFile(filename: "tracked.txt", content: "changed while on main")

        let branch = FeatureBranch(name: "yh-project-feature")
        let committer = WorktreeCommitter()
        let outcome = await committer.commitWIP(worktreePath: fixture.path, branch: branch)

        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(fixture.revParse("refs/yellowhammer/wip/yh-project-feature") == nil)
        let status = fixture.run(["status", "--porcelain"]).stdout
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

@Suite("Worktree reset-to-known-good tests")
struct WorktreeResetTests {

    @Test("Resetting after a WIP commit moves the Feature Branch to known-good and keeps the WIP ref reachable")
    func resetAfterWIPCommit() async throws {
        let fixture = GitFixture(name: "reset-after-wip-1")
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        let knownGood = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
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
        #expect(fixture.revParse(try #require(wipRef)) == wipCommit)
        #expect(fixture.revParse("HEAD") == knownGood)

        let status = fixture.run(["status", "--porcelain"]).stdout
        #expect(status.isEmpty)
    }

    @Test("A dirty Worktree is refused and the uncommitted file is left untouched")
    func dirtyWorktreeIsRefused() async throws {
        let fixture = GitFixture(name: "reset-dirty-2")
        fixture.initRepo(defaultBranch: "main")
        let knownGood = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
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
        fixture.initRepo(defaultBranch: "main")
        _ = try fixture.commit(filename: "tracked.txt", content: "initial", message: "initial commit")
        _ = fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

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
