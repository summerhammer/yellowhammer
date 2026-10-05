import Domain
import Foundation
import Repositories
import Testing

@Suite("Merge tester tests")
struct MergeTests {

    // MARK: - Single Repository Tests

    @Test("Single repo: Mainline has not moved, branch merges cleanly on top")
    func mainlineNotMoved() async throws {
        let fixture = GitFixture(name: "merge-not-moved-1")
        await fixture.initRepo(defaultBranch: "main")

        let mainSHA = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == mainSHA)
        #expect(result.mainlineRef == "refs/heads/main")
        #expect(result.isMainlineConflict == false)
    }

    @Test("Single repo: Mainline moved compatibly is clean, but clean says nothing about the build")
    func mainlineMovedCompatibly() async throws {
        let fixture = GitFixture(name: "merge-moved-compat-2")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        let featureSHA = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])
        let mainSHA = try await fixture.commit(
            filename: "other.txt", content: "other", message: "unrelated main commit"
        )

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == featureSHA)
        #expect(result.mainlineCommit == mainSHA)
    }

    @Test("Single repo: Mainline and branch edit the same file differently is a Mainline Conflict")
    func sameFileEditedDifferently() async throws {
        let fixture = GitFixture(name: "merge-conflict-3")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "f.txt", content: "base", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "f.txt", content: "feature-version", message: "feature edits f.txt")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .conflicting(paths: ["f.txt"]))
        #expect(result.isMainlineConflict == true)
        #expect(result.conflictingPaths == ["f.txt"])
    }

    @Test("Single repo: Multiple conflicting files report exactly the conflicting paths, sorted")
    func multipleConflictingFiles() async throws {
        let fixture = GitFixture(name: "merge-multi-conflict-4")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "b.txt", content: "base-b", message: "initial b")
        _ = try await fixture.commit(filename: "a.txt", content: "base-a", message: "initial a")
        _ = try await fixture.commit(filename: "quiet.txt", content: "base-quiet", message: "initial quiet")

        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "a.txt", content: "feature-a", message: "feature edits a")
        _ = try await fixture.commit(filename: "b.txt", content: "feature-b", message: "feature edits b")
        _ = try await fixture.commit(filename: "quiet.txt", content: "feature-quiet", message: "feature edits quiet")

        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "a.txt", content: "main-a", message: "main edits a")
        _ = try await fixture.commit(filename: "b.txt", content: "main-b", message: "main edits b")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .conflicting(paths: ["a.txt", "b.txt"]))
        #expect(result.conflictingPaths == ["a.txt", "b.txt"])
    }

    @Test("Single repo: Branch already an ancestor of mainline is clean")
    func branchAlreadyMerged() async throws {
        let fixture = GitFixture(name: "merge-already-merged-5")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge feature", "yh-project-feature"])

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)

        #expect(result.verdict == .clean)
    }

    @Test("Single repo: Non-existent branch is untestable")
    func nonExistentBranch() async throws {
        let fixture = GitFixture(name: "merge-nonexistent-branch-6")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(message: "initial commit")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-missing-branch", in: repo)

        guard case .untestable = result.verdict else {
            Issue.record("expected .untestable, got \(result.verdict)")
            return
        }
        #expect(result.isMainlineConflict == false)
    }

    @Test("Single repo: Non-existent repository path is untestable")
    func nonExistentPath() async throws {
        let repo = Repo(name: "ghost", path: "/tmp/nonexistent-yellowhammer-repo-\(UUID().uuidString)", role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-feat", in: repo)

        guard case .untestable = result.verdict else {
            Issue.record("expected .untestable, got \(result.verdict)")
            return
        }
    }

    @Test("Single repo: Explicit ResolvedMainline pinned to an older commit is honoured")
    func explicitResolvedMainline() async throws {
        let fixture = GitFixture(name: "merge-explicit-mainline-7")
        await fixture.initRepo(defaultBranch: "main")

        let oldMainSHA = try await fixture.commit(filename: "f.txt", content: "base", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-test-branch"])
        let branchSHA = try await fixture.commit(
            filename: "f.txt", content: "branch-version", message: "branch edits f.txt"
        )

        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let resolvedMainline = ResolvedMainline(
            repository: "app",
            defaultBranch: "main",
            ref: "refs/heads/main",
            commit: oldMainSHA
        )

        let tester = MergeTester()
        let result = await tester.testMerge(
            branch: "yh-test-branch",
            in: repo,
            mainline: resolvedMainline
        )

        #expect(result.verdict == .clean)
        #expect(result.branchCommit == branchSHA)
        #expect(result.mainlineCommit == oldMainSHA)
        #expect(result.mainlineRef == "refs/heads/main")

        // Against current HEAD of main (which also touched f.txt), the same branch conflicts.
        let headResult = await tester.testMerge(branch: "yh-test-branch", in: repo)
        #expect(headResult.verdict == .conflicting(paths: ["f.txt"]))
    }

    @Test("Invariant: a conflicting merge test leaves the working tree, index, and refs untouched")
    func mergeTestDoesNotMutateRepository() async throws {
        let fixture = GitFixture(name: "merge-invariant-8")
        await fixture.initRepo(defaultBranch: "main")

        _ = try await fixture.commit(filename: "f.txt", content: "base", message: "initial commit")
        _ = await fixture.run(["checkout", "-b", "yh-project-feature"])
        _ = try await fixture.commit(filename: "f.txt", content: "feature-version", message: "feature edits f.txt")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let statusBefore = await fixture.run(["status", "--porcelain"]).stdout
        let refsBefore = await fixture.run(["for-each-ref"]).stdout
        let headBefore = await fixture.revParse("HEAD")
        let contentsBefore = try String(contentsOf: fixture.url.appending(component: "f.txt"), encoding: .utf8)

        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        let tester = MergeTester()
        let result = await tester.testMerge(branch: "yh-project-feature", in: repo)
        #expect(result.isMainlineConflict == true)

        let statusAfter = await fixture.run(["status", "--porcelain"]).stdout
        let refsAfter = await fixture.run(["for-each-ref"]).stdout
        let headAfter = await fixture.revParse("HEAD")
        let contentsAfter = try String(contentsOf: fixture.url.appending(component: "f.txt"), encoding: .utf8)

        #expect(statusBefore == statusAfter)
        #expect(refsBefore == refsAfter)
        #expect(headBefore == headAfter)
        #expect(contentsBefore == contentsAfter)
    }

    // MARK: - Multi-Repository Feature Tests

    @Test("Multi-repo: One clean and one conflicting repository is a Mainline Conflict")
    func multiRepoOneCleanOneConflicting() async throws {
        let clean = GitFixture(name: "merge-multi-clean-9")
        await clean.initRepo(defaultBranch: "main")
        _ = try await clean.commit(filename: "init.txt", content: "initial", message: "init clean")
        _ = await clean.run(["checkout", "-b", "yh-proj-feature"])
        _ = try await clean.commit(filename: "feat.txt", content: "feature", message: "feature commit")
        _ = await clean.run(["checkout", "main"])

        let conflicting = GitFixture(name: "merge-multi-conflicting-9")
        await conflicting.initRepo(defaultBranch: "main")
        _ = try await conflicting.commit(filename: "f.txt", content: "base", message: "init conflicting")
        _ = await conflicting.run(["checkout", "-b", "yh-proj-feature"])
        _ = try await conflicting.commit(filename: "f.txt", content: "feature-version", message: "feature edits f.txt")
        _ = await conflicting.run(["checkout", "main"])
        _ = try await conflicting.commit(filename: "f.txt", content: "main-version", message: "main edits f.txt")

        let repos = [
            Repo(name: "clean-repo", path: clean.path, role: .backend),
            Repo(name: "conflicting-repo", path: conflicting.path, role: .backend)
        ]

        let branch = FeatureBranch(name: "yh-proj-feature")
        let tester = MergeTester()
        let report = await tester.evaluateMerge(
            branches: Dictionary(uniqueKeysWithValues: repos.map { ($0.name, branch) }), repos: repos
        )

        #expect(report.hasMainlineConflict == true)
        #expect(report.conflictingRepositories == ["conflicting-repo"])
        #expect(report["clean-repo"]?.verdict == .clean)
        #expect(report["conflicting-repo"]?.isMainlineConflict == true)
        #expect(report[repos[1]]?.isMainlineConflict == true)
    }

    @Test("Multi-repo: Zero repositories touched has no Mainline Conflict")
    func multiRepoZeroRepos() async throws {
        let tester = MergeTester()
        let report = await tester.evaluateMerge(branches: [:], repos: [])

        #expect(report.hasMainlineConflict == false)
        #expect(report.conflictingRepositories.isEmpty)
        #expect(report.results.isEmpty)
    }
}
