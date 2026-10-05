import Domain
import Foundation
import Repositories
import Testing

// Each Repo Lane resolves its own Feature Branch: Orca ADE may report a different `<prefix>/` per repo.

@Suite("Feature Branch prefix, per-Repo-Lane testers")
struct FeatureBranchPrefixTesterTests {
    private static let backendBranch = FeatureBranch(name: "rozd/yh-proj-auth")
    private static let webBranch = FeatureBranch(name: "team/max/yh-proj-auth")

    /// A repo with `branch` carrying one commit; merged into main when `merged`, else left unmerged.
    private func makeRepo(name: String, branch: FeatureBranch, merged: Bool) async throws -> GitFixture {
        let fixture = GitFixture(name: name)
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(message: "init \(name)")
        _ = await fixture.run(["checkout", "-b", branch.name])
        _ = try await fixture.commit(filename: "\(name).swift", content: name, message: "add \(name)")
        _ = await fixture.run(["checkout", "main"])
        if merged {
            _ = await fixture.run(["merge", "--no-ff", "-m", "merge \(name)", branch.name])
        }
        return fixture
    }

    @Test("Ancestry: each Repo Lane's own prefixed Feature Branch merged into main is 2 of 2 merged")
    func ancestryPerRepoPrefixedBranches() async throws {
        let backend = try await makeRepo(name: "prefix-anc-backend-1", branch: Self.backendBranch, merged: true)
        let web = try await makeRepo(name: "prefix-anc-web-1", branch: Self.webBranch, merged: true)
        let repos = [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "web", path: web.path, role: .web)
        ]

        let report = await AncestryTester().evaluateAncestry(
            branches: ["backend": Self.backendBranch, "web": Self.webBranch], repos: repos
        )

        #expect(report.mergedFraction.mergedCount == 2)
        #expect(report.mergedFraction.totalCount == 2)
        #expect(report.isAllMerged == true)
        #expect(report["backend"]?.branch == "rozd/yh-proj-auth")
        #expect(report["web"]?.branch == "team/max/yh-proj-auth")
    }

    @Test("Ancestry: swapping the Feature Branches between Repo Lanes finds neither, so lookup is per repo")
    func ancestrySwappedBranchesAreNotFound() async throws {
        let backend = try await makeRepo(name: "prefix-anc-backend-2", branch: Self.backendBranch, merged: true)
        let web = try await makeRepo(name: "prefix-anc-web-2", branch: Self.webBranch, merged: true)
        let repos = [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "web", path: web.path, role: .web)
        ]

        let report = await AncestryTester().evaluateAncestry(
            branches: ["backend": Self.webBranch, "web": Self.backendBranch], repos: repos
        )

        #expect(report.mergedFraction.mergedCount == 0)
        #expect(report.mergedFraction.totalCount == 2)
        #expect(report["backend"]?.isAncestor == false)
        #expect(report["web"]?.isAncestor == false)
        // A branch that does not resolve in the repo has no commit.
        #expect(report["backend"]?.branchCommit == nil)
        #expect(report["web"]?.branchCommit == nil)
    }

    @Test("Merge: two Repo Lanes with different prefixed Feature Branches merging cleanly is no Mainline Conflict")
    func mergePerRepoPrefixedBranches() async throws {
        let backend = try await makeRepo(name: "prefix-merge-backend-1", branch: Self.backendBranch, merged: false)
        let web = try await makeRepo(name: "prefix-merge-web-1", branch: Self.webBranch, merged: false)
        let repos = [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "web", path: web.path, role: .web)
        ]

        let report = await MergeTester().evaluateMerge(
            branches: ["backend": Self.backendBranch, "web": Self.webBranch], repos: repos
        )

        #expect(report.hasMainlineConflict == false)
        #expect(report["backend"]?.verdict == .clean)
        #expect(report["web"]?.verdict == .clean)
        #expect(report["backend"]?.branch == "rozd/yh-proj-auth")
        #expect(report["web"]?.branch == "team/max/yh-proj-auth")
    }
}
