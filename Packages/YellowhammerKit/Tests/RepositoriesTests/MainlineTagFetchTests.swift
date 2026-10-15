import Domain
import Foundation
import Repositories
import Testing

@Suite("Act-start tag fetch for tag producers")
struct MainlineTagFetchTests {
    /// A bare `origin` holding `main` and a tag `v1.0.0` on a commit no branch contains, so only the tag fetch
    /// (never the mainline fetch's tag auto-following) can bring the tag in; and a clone of it that tracks `main`.
    private struct World: ~Copyable {
        let remote: GitFixture
        let publisher: GitFixture
        let clone: GitFixture
        let tagSHA: String
    }

    private func world(_ name: String) async throws -> World {
        let remote = GitFixture(name: "tag-remote-\(name)")
        await remote.initRepo(bare: true, defaultBranch: "main")

        let publisher = GitFixture(name: "tag-publisher-\(name)")
        await publisher.initRepo(defaultBranch: "main")
        await publisher.addRemote(name: "origin", url: remote.path)
        try await publisher.commit(message: "published main \(name)")
        _ = await publisher.run(["push", "origin", "main"])
        _ = await publisher.run(["checkout", "-b", "release-side"])
        let tagSHA = try await publisher.commit(filename: "release.txt", content: "release", message: "release \(name)")
        _ = await publisher.run(["tag", "v1.0.0"])
        _ = await publisher.run(["push", "origin", "v1.0.0"])

        let clone = GitFixture(name: "tag-clone-\(name)")
        await clone.initRepo(defaultBranch: "main")
        await clone.addRemote(name: "origin", url: remote.path)
        _ = await clone.run(["fetch", "origin", "+refs/heads/main:refs/remotes/origin/main"])
        await clone.setRemoteHead(remote: "origin", branch: "main")
        return World(remote: remote, publisher: publisher, clone: clone, tagSHA: tagSHA)
    }

    private func repositories(producer: Repo, via: RepoDependencyVia) -> ProjectRepositories {
        let consumer = Repo(
            name: "consumer", path: "/nonexistent/consumer", role: .backend,
            consumes: [RepoDependency(producer: producer.name, via: via)]
        )
        return ProjectRepositories(workingRepos: [consumer, producer])
    }

    @Test("A tag producer's tags are fetched at Act start, with no tag failure")
    func tagProducerGetsItsTags() async throws {
        let world = try await world("fetch")
        await #expect(world.clone.revParse("refs/tags/v1.0.0") == nil)

        let producer = Repo(name: "contracts", path: world.clone.path, role: .backend)
        let result = await MainlineRefresher().refresh(repositories: repositories(producer: producer, via: .tag))

        await #expect(world.clone.revParse("refs/tags/v1.0.0^{commit}") == world.tagSHA)
        #expect(result.tagFetchFailures.isEmpty)
        #expect(result.failures.isEmpty)
    }

    @Test("A local tag is never overwritten: the rejection is reported and the mainline refresh stays good")
    func existingLocalTagIsNeverOverwritten() async throws {
        let world = try await world("clobber")
        let localSHA = try await world.clone.commit(message: "local-only commit")
        _ = await world.clone.run(["tag", "v1.0.0"])
        #expect(localSHA != world.tagSHA)

        let producer = Repo(name: "contracts", path: world.clone.path, role: .backend)
        let result = await MainlineRefresher().refresh(repositories: repositories(producer: producer, via: .tag))

        await #expect(world.clone.revParse("refs/tags/v1.0.0^{commit}") == localSHA)
        #expect(result.tagFetchFailures.map(\.repository) == ["contracts"])
        #expect(result.failures.isEmpty)
        #expect(result.mainlines["contracts"]?.ref == "refs/remotes/origin/main")
    }

    @Test("A Repo that is not a tag producer gets no tag fetched, whether unreferenced or a mainline producer")
    func nonTagProducersFetchNoTags() async throws {
        let world = try await world("mainline-only")
        let producer = Repo(name: "contracts", path: world.clone.path, role: .backend)

        let viaMainline = await MainlineRefresher().refresh(
            repositories: repositories(producer: producer, via: .mainline)
        )
        await #expect(world.clone.revParse("refs/tags/v1.0.0") == nil)
        #expect(viaMainline.tagFetchFailures.isEmpty)

        let unreferenced = await MainlineRefresher()
            .refresh(repositories: ProjectRepositories(workingRepos: [producer]))
        await #expect(world.clone.revParse("refs/tags/v1.0.0") == nil)
        #expect(unreferenced.tagFetchFailures.isEmpty)
    }

    @Test("A tag producer with no origin is skipped without a failure")
    func tagProducerWithoutOriginIsSkipped() async throws {
        let local = GitFixture(name: "tag-no-origin")
        await local.initRepo(defaultBranch: "main")
        try await local.commit(message: "only commit")
        let producer = Repo(name: "contracts", path: local.path, role: .backend)

        let result = await MainlineRefresher().refresh(repositories: repositories(producer: producer, via: .tag))
        #expect(result.tagFetchFailures.isEmpty)
    }

    @Test("When the credential cannot be resolved nothing is fetched and a tag failure is recorded")
    func unresolvedCredentialRecordsATagFailure() async throws {
        struct Unresolvable: Error {}
        let world = try await world("credential")
        let producer = Repo(name: "contracts", path: world.clone.path, role: .backend)

        let result = await MainlineRefresher(credential: { throw Unresolvable() })
            .refresh(repositories: repositories(producer: producer, via: .tag))

        await #expect(world.clone.revParse("refs/tags/v1.0.0") == nil)
        #expect(result.tagFetchFailures.map(\.repository) == ["contracts"])
        #expect(result.tagFetchFailures.first?.reason.contains("Code Hosting Connection") == true)
    }
}
