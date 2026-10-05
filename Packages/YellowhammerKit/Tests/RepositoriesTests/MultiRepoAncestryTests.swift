import Domain
import Foundation
import Repositories
import Testing

@Suite("Multi-repository ancestry tests")
struct MultiRepoAncestryTests {

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

        #expect(report.mergedFraction.mergedCount == 3)
        #expect(report.mergedFraction.totalCount == 3)
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

        #expect(report.mergedFraction.mergedCount == 1)
        #expect(report.mergedFraction.totalCount == 3)
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

        #expect(report.mergedFraction.mergedCount == 0)
        #expect(report.mergedFraction.totalCount == 2)
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

        #expect(report.mergedFraction.mergedCount == 0)
        #expect(report.mergedFraction.totalCount == 0)
        #expect(report.mergedFraction.description == "0 of 0 merged")
        #expect(report.isAllMerged == false)
        #expect(report.unmergedRepositories.isEmpty)
        #expect(report.mergedRepositories.isEmpty)
    }

    // MARK: - FeatureBranch & MergedFraction Types

    @Test("FeatureBranch: Deterministic naming and slugification")
    func featureBranchNaming() {
        let branch1 = FeatureBranch(
            name: WorktreeName(project: "yellowhammer", feature: "bound unanswered nights").rawValue
        )
        #expect(branch1.name == "yh-yellowhammer-bound-unanswered-nights")
        #expect(branch1.description == "yh-yellowhammer-bound-unanswered-nights")

        let projectID = ProjectID(rawValue: "core")!
        let featureName = FeatureName(rawValue: "auth/tokens")!
        let branch2 = FeatureBranch(name: WorktreeName(projectID: projectID, feature: featureName).rawValue)
        #expect(branch2.name == "yh-core-auth-tokens")

        let branchLiteral: FeatureBranch = "yh-literal-branch"
        #expect(branchLiteral.name == "yh-literal-branch")
    }

    @Test("MergedFraction: Formatting and status predicates")
    func mergedFractionProperties() {
        let mf0 = MergedFraction(mergedCount: 0, totalCount: 3)
        #expect(mf0.mergedCount == 0)
        #expect(mf0.totalCount == 3)
        #expect(mf0.description == "0 of 3 merged")
        #expect(mf0.isUnmerged == true)
        #expect(mf0.isPartiallyMerged == false)
        #expect(mf0.isFullyMerged == false)

        let mf1 = MergedFraction(mergedCount: 1, totalCount: 3)
        #expect(mf1.mergedCount == 1)
        #expect(mf1.totalCount == 3)
        #expect(mf1.description == "1 of 3 merged")
        #expect(mf1.isUnmerged == false)
        #expect(mf1.isPartiallyMerged == true)
        #expect(mf1.isFullyMerged == false)

        let mf3 = MergedFraction(mergedCount: 3, totalCount: 3)
        #expect(mf3.mergedCount == 3)
        #expect(mf3.totalCount == 3)
        #expect(mf3.description == "3 of 3 merged")
        #expect(mf3.isUnmerged == false)
        #expect(mf3.isPartiallyMerged == false)
        #expect(mf3.isFullyMerged == true)
    }
}
