import Domain
import Foundation
import Journal
import Repositories
import Testing

@Suite("Mainline refresh tests")
struct MainlineRefreshTests {
    // MARK: - Test 1: Fetch success

    @Test("Test 1: Working repo with bare remote origin fetches new commit and updates remote tracking ref")
    func fetchSuccessUpdatesRemoteTrackingRef() async throws {
        // Create bare remote repository
        let remote = GitFixture(name: "remote-1")
        await remote.initRepo(bare: true, defaultBranch: "main")

        // Create local working repository cloned/connected to remote
        let local = GitFixture(name: "local-1")
        await local.initRepo(defaultBranch: "main")
        await local.addRemote(name: "origin", url: remote.path)

        // Seed initial commit and push to remote
        let initialSHA = try await local.commit(message: "initial commit")
        _ = await local.run(["push", "-u", "origin", "main"])
        await local.setRemoteHead(remote: "origin", branch: "main")

        // Verify initial remote-tracking ref
        await #expect(local.revParse("refs/remotes/origin/main") == initialSHA)

        // Now, another checkout pushes a new commit to the bare remote
        let pusher = GitFixture(name: "pusher-1")
        await pusher.initRepo(defaultBranch: "main")
        await pusher.addRemote(name: "origin", url: remote.path)
        _ = await pusher.run(["fetch", "origin", "main"])
        _ = await pusher.run(["checkout", "main"])
        let newSHA = try await pusher.commit(filename: "newfile.txt", content: "hello", message: "second commit")
        _ = await pusher.run(["push", "origin", "main"])

        // Remote has newSHA, but local's remote-tracking ref still has initialSHA
        await #expect(local.revParse("refs/remotes/origin/main") == initialSHA)

        // Refresh mainline
        let repo = Repo(name: "app", path: local.path, role: .backend)
        let refresher = MainlineRefresher()
        let (mainline, failure) = await refresher.refreshWorkingRepo(repo)

        // Assertions:
        // 1. No failure recorded
        #expect(failure == nil)
        // 2. Returns new commit SHA
        let resolved = try #require(mainline)
        #expect(resolved.commit == newSHA)
        #expect(resolved.ref == "refs/remotes/origin/main")
        #expect(resolved.defaultBranch == "main")
        #expect(resolved.repository == "app")
        // 3. Remote-tracking ref is updated to new commit
        await #expect(local.revParse("refs/remotes/origin/main") == newSHA)
        // 4. Working tree and local branch were NOT updated (non-destructive)
        await #expect(local.revParse("refs/heads/main") == initialSHA)
    }

    // MARK: - Test 2: Fetch failure fallback

    @Test("Test 2: Working repo with unreachable origin falls back to cached ref and reports failure")
    func fetchFailureFallsBackToCachedRef() async throws {
        // Create bare remote repository and populate it
        let remote = GitFixture(name: "remote-2")
        await remote.initRepo(bare: true, defaultBranch: "main")

        let local = GitFixture(name: "local-2")
        await local.initRepo(defaultBranch: "main")
        await local.addRemote(name: "origin", url: remote.path)

        let initialSHA = try await local.commit(message: "initial commit")
        _ = await local.run(["push", "-u", "origin", "main"])
        await local.setRemoteHead(remote: "origin", branch: "main")

        await #expect(local.revParse("refs/remotes/origin/main") == initialSHA)

        // Make remote unreachable by deleting the remote directory
        try FileManager.default.removeItem(at: remote.url)

        // Refresh mainline
        let repo = Repo(name: "service", path: local.path, role: .backend)
        let refresher = MainlineRefresher()
        let (mainline, failure) = await refresher.refreshWorkingRepo(repo)

        // Assertions:
        // 1. Failure is recorded with reason
        let fail = try #require(failure)
        #expect(fail.repository == "service")
        #expect(!fail.reason.isEmpty)
        // 2. Continues on the cached ref (does not fail or return nil)
        let resolved = try #require(mainline)
        #expect(resolved.commit == initialSHA)
        #expect(resolved.ref == "refs/remotes/origin/main")
        #expect(resolved.defaultBranch == "main")
    }

    // MARK: - Test 3: Spec Source never fetched

    @Test("Test 3: Spec Source has remote with newer commits; mainline refresh leaves remote unfetched")
    func specSourceNeverFetched() async throws {
        // Create remote for spec
        let specRemote = GitFixture(name: "spec-remote-3")
        await specRemote.initRepo(bare: true, defaultBranch: "main")

        // Create local spec checkout
        let localSpec = GitFixture(name: "local-spec-3")
        await localSpec.initRepo(defaultBranch: "main")
        await localSpec.addRemote(name: "origin", url: specRemote.path)

        let initialSHA = try await localSpec.commit(message: "spec v1")
        _ = await localSpec.run(["push", "-u", "origin", "main"])
        await localSpec.setRemoteHead(remote: "origin", branch: "main")

        // Another contributor pushes spec v2 to the remote
        let other = GitFixture(name: "spec-author-3")
        await other.initRepo(defaultBranch: "main")
        await other.addRemote(name: "origin", url: specRemote.path)
        _ = await other.run(["fetch", "origin", "main"])
        _ = await other.run(["checkout", "main"])
        let newSHA = try await other.commit(filename: "spec.md", content: "# Spec v2", message: "spec v2")
        _ = await other.run(["push", "origin", "main"])

        // Resolve Spec Source mainline
        let specSource = SpecSource(path: localSpec.path)
        let refresher = MainlineRefresher()
        let resolved = await refresher.resolveSpecSource(specSource)

        // Assertions:
        // 1. Resolves local checkout HEAD (initialSHA, not newSHA)
        let mainline = try #require(resolved)
        #expect(mainline.commit == initialSHA)
        #expect(mainline.ref == "refs/heads/main")
        #expect(mainline.defaultBranch == "main")
        // 2. Remote tracking ref in localSpec was NEVER fetched
        await #expect(localSpec.revParse("refs/remotes/origin/main") == initialSHA)
        await #expect(localSpec.revParse("refs/remotes/origin/main") != newSHA)
    }
}
