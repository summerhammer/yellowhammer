import Domain
import Foundation
import Repositories
import Testing

@Suite("Ancestry tester tests")
struct AncestryTests {

    // MARK: - Single Repository Tests

    @Test("Single repo: Branch merged into mainline with merge commit is an ancestor")
    func singleRepoMergedBranchWithMergeCommit() async throws {
        let fixture = GitFixture(name: "ancestry-merged-1")
        await fixture.initRepo(defaultBranch: "main")

        let initialSHA = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        await #expect(fixture.revParse("main") == initialSHA)

        // Create feature branch and commit
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        // Switch back to main and merge with a merge commit
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--no-ff", "-m", "Merge branch yh-project-feature", "yh-project-feature"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-project-feature", in: repo)

        #expect(result.isAncestor == true)
        #expect(result.repository == "app")
        #expect(result.branch == "yh-project-feature")
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit != nil)
    }

    @Test("Single repo: Branch fast-forward merged into mainline is an ancestor")
    func singleRepoFastForwardMergedBranch() async throws {
        let fixture = GitFixture(name: "ancestry-ff-2")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")

        // Create feature branch and commit
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        // Switch back to main and fast-forward merge
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--ff-only", "yh-project-feature"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: FeatureBranch(name: "yh-project-feature"), in: repo)

        #expect(result.isAncestor == true)
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == featureSHA)
    }

    @Test("Single repo: Unmerged branch is not an ancestor")
    func singleRepoUnmergedBranch() async throws {
        let fixture = GitFixture(name: "ancestry-unmerged-3")
        await fixture.initRepo(defaultBranch: "main")

        let initialSHA = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")

        // Create feature branch and commit
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        // Switch back to main; do not merge
        _ = await fixture.run(["checkout", "main"])

        let repo = Repo(name: "service", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-project-feature", in: repo)

        #expect(result.isAncestor == false)
        #expect(result.repository == "service")
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == initialSHA)
    }

    @Test("Single repo: Mainline moved ahead independently without merging branch")
    func singleRepoMainlineMovedAheadWithoutMerging() async throws {
        let fixture = GitFixture(name: "ancestry-moved-4")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")

        // Create feature branch and commit
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        // Switch to main and add unrelated commits
        _ = await fixture.run(["checkout", "main"])
        let newMainSHA = try await fixture.commit(filename: "other.txt", content: "other", message: "main commit")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-project-feature", in: repo)

        #expect(result.isAncestor == false)
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == newMainSHA)
    }

    @Test("Single repo: Mainline moved ahead after merging branch")
    func singleRepoMainlineMovedAheadAfterMerging() async throws {
        let fixture = GitFixture(name: "ancestry-merged-then-moved-5")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")

        // Create feature branch and commit
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")

        // Switch to main, merge, then add another commit
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge", "yh-project-feature"])
        let latestMainSHA = try await fixture.commit(filename: "latest.txt", content: "latest", message: "latest main")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-project-feature", in: repo)

        #expect(result.isAncestor == true)
        #expect(result.mainlineCommit == latestMainSHA)
    }

    @Test("Single repo: Branch pointing to same commit as mainline is an ancestor")
    func singleRepoBranchSameAsMainline() async throws {
        let fixture = GitFixture(name: "ancestry-same-6")
        await fixture.initRepo(defaultBranch: "main")

        let initialSHA = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")

        // Create branch without extra commits
        _ = await fixture.run(["branch", "yh-project-feature", "main"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-project-feature", in: repo)

        #expect(result.isAncestor == true)
        #expect(result.branchCommit == initialSHA)
        #expect(result.mainlineCommit == initialSHA)
    }

    @Test("Single repo: Non-existent branch returns isAncestor = false")
    func singleRepoNonExistentBranch() async throws {
        let fixture = GitFixture(name: "ancestry-nonexistent-7")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(message: "initial commit")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-missing-branch", in: repo)

        #expect(result.isAncestor == false)
        #expect(result.branchCommit == nil)
    }

    @Test("Single repo: Non-existent repository path returns isAncestor = false")
    func singleRepoNonExistentPath() async throws {
        let repo = Repo(name: "ghost", path: "/tmp/nonexistent-yellowhammer-repo-\(UUID().uuidString)", role: .backend)
        let tester = AncestryTester()
        let result = await tester.testAncestry(branch: "yh-feat", in: repo)

        #expect(result.isAncestor == false)
        #expect(result.branchCommit == nil)
        #expect(result.mainlineCommit == nil)
    }

    @Test("Single repo: Explicit ResolvedMainline is used directly")
    func singleRepoExplicitResolvedMainline() async throws {
        let fixture = GitFixture(name: "ancestry-explicit-8")
        await fixture.initRepo(defaultBranch: "main")

        let initialSHA = try await fixture.commit(message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-test-branch"])
        let branchSHA = try await fixture.commit(filename: "feat.txt", content: "data", message: "feature commit")

        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--ff-only", "yh-test-branch"])
        let parsed = await fixture.revParse("main")
        let mergedMainSHA = try #require(parsed)

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let resolvedMainline = ResolvedMainline(
            repository: "app",
            defaultBranch: "main",
            ref: "refs/heads/main",
            commit: mergedMainSHA
        )

        let tester = AncestryTester()
        let result = await tester.testAncestry(
            branch: "yh-test-branch",
            in: repo,
            mainline: resolvedMainline
        )

        #expect(result.isAncestor == true)
        #expect(result.branchCommit == branchSHA)
        #expect(result.mainlineCommit == mergedMainSHA)

        // If we provide the older initialSHA as mainline, branch is NOT an ancestor of initialSHA
        let olderMainline = ResolvedMainline(
            repository: "app",
            defaultBranch: "main",
            ref: "refs/heads/main",
            commit: initialSHA
        )
        let olderResult = await tester.testAncestry(
            branch: "yh-test-branch",
            in: repo,
            mainline: olderMainline
        )
        #expect(olderResult.isAncestor == false)
    }
}

// feature-authoring/select-the-next-feature #tested-tip: the recorded pushed commit is tested, and the branch
// name only when none was recorded or the repository no longer has it.
@Suite("Ancestry of a recorded tip")
struct RecordedTipAncestryTests {
    private func populateMerged(_ fixture: borrowing GitFixture) async throws -> String {
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        let tip = try await fixture.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge", "yh-feature"])
        return tip
    }

    @Test("The recorded commit is an ancestor although its branch ref is gone")
    func recordedCommitWithoutBranchRef() async throws {
        let fixture = GitFixture(name: "tip-no-ref-\(UUID().uuidString)")
        let tip = try await populateMerged(fixture)
        _ = await fixture.run(["branch", "-D", "yh-feature"])
        let repo = Repo(name: "app", path: fixture.path, role: .backend)

        let result = await AncestryTester().testAncestry(branch: "yh-feature", recordedCommit: tip, in: repo)

        #expect(result.branchCommit == tip)
        #expect(result.isAncestor)
    }

    @Test("The recorded commit is tested, not a branch that has moved on")
    func recordedCommitWinsOverALaterBranchTip() async throws {
        let fixture = GitFixture(name: "tip-later-\(UUID().uuidString)")
        let tip = try await populateMerged(fixture)
        _ = await fixture.run(["checkout", "yh-feature"])
        let later = try await fixture.commit(filename: "later.txt", content: "later", message: "after the push")
        _ = await fixture.run(["checkout", "main"])
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = AncestryTester()

        let byBranch = await tester.testAncestry(branch: "yh-feature", in: repo)
        let byCommit = await tester.testAncestry(branch: "yh-feature", recordedCommit: tip, in: repo)

        #expect(byBranch.branchCommit == later)
        #expect(!byBranch.isAncestor)
        #expect(byCommit.isAncestor)
    }

    @Test("No recorded commit, or one the repository lacks, reads the branch; with neither the tip is unresolved")
    func fallsBackToTheBranchName() async throws {
        let fixture = GitFixture(name: "tip-fallback-\(UUID().uuidString)")
        let tip = try await populateMerged(fixture)
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let missing = String(repeating: "cd", count: 20)
        let tester = AncestryTester()

        let none = await tester.testAncestry(branch: "yh-feature", recordedCommit: nil, in: repo)
        let gone = await tester.testAncestry(branch: "yh-feature", recordedCommit: missing, in: repo)
        let neither = await tester.testAncestry(branch: "nope", recordedCommit: missing, in: repo)
        let malformed = await tester.testAncestry(branch: "nope", recordedCommit: "--all", in: repo)

        #expect(none.branchCommit == tip)
        #expect(gone.branchCommit == tip)
        #expect(neither.branchCommit == nil)
        #expect(malformed.branchCommit == nil)
    }

    @Test("Tips: a repository absent from the map, or with no branch and no commit, is unresolved")
    func evaluateAncestryByTips() async throws {
        let fixture = GitFixture(name: "tip-map-\(UUID().uuidString)")
        let tip = try await populateMerged(fixture)
        let repos = ["merged", "bare", "absent"].map { Repo(name: $0, path: fixture.path, role: .backend) }

        let report = await AncestryTester().evaluateAncestry(
            tips: [
                "merged": TestedTip(branch: nil, recordedCommit: tip),
                "bare": TestedTip(branch: nil)
            ],
            repos: repos
        )

        #expect(report["merged"]?.isAncestor == true)
        #expect(report["bare"]?.branchCommit == nil)
        #expect(report["absent"]?.branchCommit == nil)
        #expect(report.mergedFraction == MergedFraction(mergedCount: 1, totalCount: 3))
    }
}
