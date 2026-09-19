import Domain
import Foundation
import Repositories
import Testing

@Suite("Mainline default branch resolution")
struct MainlineResolutionTests {
    @Test("Rule 1: Explicit default branch override takes precedence")
    func explicitOverrideTakesPrecedence() async throws {
        let fixture = GitFixture()
        await fixture.initRepo()
        try await fixture.commit(message: "initial")

        let repo = Repo(name: "test-repo", path: fixture.path, role: .backend, defaultBranch: "feature-trunk")
        let refresher = MainlineRefresher()
        let resolved = await refresher.resolveDefaultBranch(for: repo, in: fixture.path)
        #expect(resolved == "feature-trunk")
    }

    @Test("Rule 2: Resolves from refs/remotes/origin/HEAD symbolic ref")
    func resolvesFromRemoteHeadSymbolicRef() async throws {
        let fixture = GitFixture()
        await fixture.initRepo()
        try await fixture.commit(message: "initial")
        await fixture.addRemote(name: "origin", url: "https://example.com/repo.git")
        await fixture.setRemoteHead(remote: "origin", branch: "develop")

        let repo = Repo(name: "test-repo", path: fixture.path, role: .backend)
        let refresher = MainlineRefresher()
        let resolved = await refresher.resolveDefaultBranch(for: repo, in: fixture.path)
        #expect(resolved == "develop")
    }

    @Test("Rule 3: Probes refs/remotes/origin/main when origin/HEAD absent")
    func probesOriginMain() async throws {
        let fixture = GitFixture()
        await fixture.initRepo()
        let sha = try await fixture.commit(message: "initial")
        await fixture.addRemote(name: "origin", url: "https://example.com/repo.git")
        // Create refs/remotes/origin/main manually
        _ = await fixture.run(["update-ref", "refs/remotes/origin/main", sha])

        let repo = Repo(name: "test-repo", path: fixture.path, role: .backend)
        let refresher = MainlineRefresher()
        let resolved = await refresher.resolveDefaultBranch(for: repo, in: fixture.path)
        #expect(resolved == "main")
    }

    @Test("Rule 4: Probes refs/remotes/origin/master when origin/main absent")
    func probesOriginMaster() async throws {
        let fixture = GitFixture()
        await fixture.initRepo()
        let sha = try await fixture.commit(message: "initial")
        await fixture.addRemote(name: "origin", url: "https://example.com/repo.git")
        // Create refs/remotes/origin/master manually
        _ = await fixture.run(["update-ref", "refs/remotes/origin/master", sha])

        let repo = Repo(name: "test-repo", path: fixture.path, role: .backend)
        let refresher = MainlineRefresher()
        let resolved = await refresher.resolveDefaultBranch(for: repo, in: fixture.path)
        #expect(resolved == "master")
    }

    @Test("Rule 5: With no remote, resolves local branch")
    func resolvesLocalBranchWithNoRemote() async throws {
        let fixture = GitFixture()
        await fixture.initRepo(defaultBranch: "main")
        try await fixture.commit(message: "initial")

        let repo = Repo(name: "test-repo", path: fixture.path, role: .backend)
        let refresher = MainlineRefresher()
        let resolved = await refresher.resolveDefaultBranch(for: repo, in: fixture.path)
        #expect(resolved == "main")
    }
}
