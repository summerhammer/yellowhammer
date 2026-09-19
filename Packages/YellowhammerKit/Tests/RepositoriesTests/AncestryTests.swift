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

    // MARK: - Multi-Repository Feature Tests (k of N merged fraction)

    @Test("Multi-repo: All N repositories merged yields k = N and isAllMerged = true")
    func multiRepoAllMerged() async throws {
        let backend = GitFixture(name: "multi-backend-1")
        await backend.initRepo(defaultBranch: "main")
        _ = try await backend.commit(message: "init backend")
        _ = await backend.run(["checkout", "-b", "yh-proj-auth"])
        _ = try await backend.commit(filename: "api.swift", content: "auth", message: "add auth API")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge auth", "yh-proj-auth"])

        let web = GitFixture(name: "multi-web-1")
        await web.initRepo(defaultBranch: "main")
        _ = try await web.commit(message: "init web")
        _ = await web.run(["checkout", "-b", "yh-proj-auth"])
        _ = try await web.commit(filename: "view.swift", content: "ui", message: "add auth UI")
        _ = await web.run(["checkout", "main"])
        _ = await web.run(["merge", "--no-ff", "-m", "merge auth", "yh-proj-auth"])

        let mobile = GitFixture(name: "multi-mobile-1")
        await mobile.initRepo(defaultBranch: "main")
        _ = try await mobile.commit(message: "init mobile")
        _ = await mobile.run(["checkout", "-b", "yh-proj-auth"])
        _ = try await mobile.commit(filename: "app.swift", content: "cmd", message: "add auth mobile")
        _ = await mobile.run(["checkout", "main"])
        _ = await mobile.run(["merge", "--no-ff", "-m", "merge auth", "yh-proj-auth"])

        let repos = [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "web", path: web.path, role: .web),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ]

        let branch = FeatureBranch(name: "yh-proj-auth")
        let tester = AncestryTester()
        let report = await tester.evaluateAncestry(branch: branch, repos: repos)

        #expect(report.mergedFraction.k == 3)
        #expect(report.mergedFraction.n == 3)
        #expect(report.mergedFraction.description == "3 of 3 merged")
        #expect(report.mergedFraction.formatted == "3 of 3 merged")
        #expect(report.isAllMerged == true)
        #expect(report.mergedFraction.isFullyMerged == true)
        #expect(report.mergedFraction.isPartiallyMerged == false)
        #expect(report.mergedFraction.isUnmerged == false)
        #expect(report.unmergedRepositories.isEmpty)
        #expect(report.mergedRepositories == ["backend", "web", "mobile"])
        #expect(report["backend"]?.isAncestor == true)
        #expect(report["web"]?.isAncestor == true)
        #expect(report["mobile"]?.isAncestor == true)
    }

    @Test("Multi-repo: Partial Landing where 1 of 3 repositories is merged")
    func multiRepoPartialLanding() async throws {
        let backend = GitFixture(name: "multi-backend-2")
        await backend.initRepo(defaultBranch: "main")
        _ = try await backend.commit(message: "init backend")
        _ = await backend.run(["checkout", "-b", "yh-proj-partial"])
        _ = try await backend.commit(filename: "api.swift", content: "partial", message: "partial API")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge partial", "yh-proj-partial"])

        let web = GitFixture(name: "multi-web-2")
        await web.initRepo(defaultBranch: "main")
        _ = try await web.commit(message: "init web")
        _ = await web.run(["checkout", "-b", "yh-proj-partial"])
        _ = try await web.commit(filename: "view.swift", content: "view", message: "unmerged view")
        _ = await web.run(["checkout", "main"])
        // Not merged

        let mobile = GitFixture(name: "multi-mobile-2")
        await mobile.initRepo(defaultBranch: "main")
        _ = try await mobile.commit(message: "init mobile")
        _ = await mobile.run(["checkout", "-b", "yh-proj-partial"])
        _ = try await mobile.commit(filename: "app.swift", content: "mobile", message: "unmerged mobile")
        _ = await mobile.run(["checkout", "main"])
        // Not merged

        let repos = [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "web", path: web.path, role: .web),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ]

        let branch = FeatureBranch(name: "yh-proj-partial")
        let tester = AncestryTester()
        let report = await tester.evaluateAncestry(branch: branch, repos: repos)

        #expect(report.mergedFraction.k == 1)
        #expect(report.mergedFraction.n == 3)
        #expect(report.mergedFraction.description == "1 of 3 merged")
        #expect(report.isAllMerged == false)
        #expect(report.mergedFraction.isFullyMerged == false)
        #expect(report.mergedFraction.isPartiallyMerged == true)
        #expect(report.mergedFraction.isUnmerged == false)
        #expect(report.unmergedRepositories == ["web", "mobile"])
        #expect(report.mergedRepositories == ["backend"])
        #expect(report["backend"]?.isAncestor == true)
        #expect(report["web"]?.isAncestor == false)
        #expect(report["mobile"]?.isAncestor == false)
    }

    @Test("Multi-repo: None merged yields 0 of N merged")
    func multiRepoNoneMerged() async throws {
        let backend = GitFixture(name: "multi-backend-3")
        await backend.initRepo(defaultBranch: "main")
        _ = try await backend.commit(filename: "init.txt", content: "init", message: "init backend")
        _ = await backend.run(["checkout", "-b", "yh-proj-zero"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feat")
        _ = await backend.run(["checkout", "main"])

        let web = GitFixture(name: "multi-web-3")
        await web.initRepo(defaultBranch: "main")
        _ = try await web.commit(filename: "init.txt", content: "init", message: "init web")
        _ = await web.run(["checkout", "-b", "yh-proj-zero"])
        _ = try await web.commit(filename: "feat.txt", content: "feat", message: "feat")
        _ = await web.run(["checkout", "main"])

        let repos = [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "web", path: web.path, role: .web)
        ]

        let tester = AncestryTester()
        let report = await tester.evaluateAncestry(branchName: "yh-proj-zero", repos: repos)

        #expect(report.mergedFraction.k == 0)
        #expect(report.mergedFraction.n == 2)
        #expect(report.mergedFraction.description == "0 of 2 merged")
        #expect(report.isAllMerged == false)
        #expect(report.mergedFraction.isFullyMerged == false)
        #expect(report.mergedFraction.isPartiallyMerged == false)
        #expect(report.mergedFraction.isUnmerged == true)
        #expect(report.unmergedRepositories == ["backend", "web"])
        #expect(report.mergedRepositories.isEmpty)
    }

    @Test("Multi-repo: Zero repositories touched yields 0 of 0 merged")
    func multiRepoZeroRepos() async throws {
        let tester = AncestryTester()
        let report = await tester.evaluateAncestry(branchName: "yh-proj-empty", repos: [])

        #expect(report.mergedFraction.k == 0)
        #expect(report.mergedFraction.n == 0)
        #expect(report.mergedFraction.description == "0 of 0 merged")
        #expect(report.isAllMerged == false)
        #expect(report.unmergedRepositories.isEmpty)
        #expect(report.mergedRepositories.isEmpty)
    }

    // MARK: - FeatureBranch & MergedFraction Types

    @Test("FeatureBranch: Deterministic naming and slugification")
    func featureBranchNaming() {
        let branch1 = FeatureBranch(project: "yellowhammer", feature: "bound unanswered nights")
        #expect(branch1.name == "yh-yellowhammer-bound-unanswered-nights")
        #expect(branch1.description == "yh-yellowhammer-bound-unanswered-nights")

        let projectID = ProjectID(rawValue: "core")!
        let featureName = FeatureName(rawValue: "auth/tokens")!
        let branch2 = FeatureBranch(projectID: projectID, feature: featureName)
        #expect(branch2.name == "yh-core-auth-tokens")

        let branchLiteral: FeatureBranch = "yh-literal-branch"
        #expect(branchLiteral.name == "yh-literal-branch")
    }

    @Test("MergedFraction: Formatting and status predicates")
    func mergedFractionProperties() {
        let mf0 = MergedFraction(mergedCount: 0, totalCount: 3)
        #expect(mf0.k == 0)
        #expect(mf0.n == 3)
        #expect(mf0.description == "0 of 3 merged")
        #expect(mf0.isUnmerged == true)
        #expect(mf0.isPartiallyMerged == false)
        #expect(mf0.isFullyMerged == false)

        let mf1 = MergedFraction(mergedCount: 1, totalCount: 3)
        #expect(mf1.k == 1)
        #expect(mf1.n == 3)
        #expect(mf1.description == "1 of 3 merged")
        #expect(mf1.isUnmerged == false)
        #expect(mf1.isPartiallyMerged == true)
        #expect(mf1.isFullyMerged == false)

        let mf3 = MergedFraction(mergedCount: 3, totalCount: 3)
        #expect(mf3.k == 3)
        #expect(mf3.n == 3)
        #expect(mf3.description == "3 of 3 merged")
        #expect(mf3.isUnmerged == false)
        #expect(mf3.isPartiallyMerged == false)
        #expect(mf3.isFullyMerged == true)
    }
}
