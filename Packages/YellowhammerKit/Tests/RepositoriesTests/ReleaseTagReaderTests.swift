import Foundation
import Repositories
import Testing

@Suite("Reading release-shaped tags")
struct ReleaseTagReaderTests {
    @Test("Only MAJOR.MINOR.PATCH tags, with an optional v, are release-shaped; newest version first")
    func filtersAndOrdersReleaseTags() async throws {
        let repo = GitFixture(name: "release-tags-filter")
        await repo.initRepo(defaultBranch: "main")
        let commit = try await repo.commit(message: "only commit")
        for tag in ["v1.2.3", "1.10.0", "v1.2.3-rc.1", "release-1", "v1.2", "v1.2.3.4", "v2.0.0", "va.b.c"] {
            await repo.run(["tag", tag])
        }

        let tags = await ReleaseTagReader().releaseTags(in: repo.path)

        #expect(tags.map(\.name) == ["v2.0.0", "1.10.0", "v1.2.3"])
        #expect(tags.allSatisfy { $0.commit == commit })
    }

    @Test("An annotated tag reports the commit it peels to, not the tag object")
    func annotatedTagIsPeeled() async throws {
        let repo = GitFixture(name: "release-tags-annotated")
        await repo.initRepo(defaultBranch: "main")
        let commit = try await repo.commit(message: "tagged commit")
        await repo.run(["tag", "-a", "v1.0.0", "-m", "release one"])
        let tagObject = try #require(await repo.revParse("refs/tags/v1.0.0"))
        #expect(tagObject != commit)

        let tags = await ReleaseTagReader().releaseTags(in: repo.path)

        #expect(tags.count == 1)
        #expect(tags.first?.commit == commit)
    }

    @Test("A path with no repository or no tags yields no release tags")
    func noTags() async throws {
        let repo = GitFixture(name: "release-tags-none")
        await repo.initRepo(defaultBranch: "main")
        try await repo.commit(message: "untagged")
        #expect(await ReleaseTagReader().releaseTags(in: repo.path).isEmpty)
        #expect(await ReleaseTagReader().releaseTags(in: repo.path + "/missing").isEmpty)
    }

    @Test("contains is true for an ancestor or the same commit and false for a later commit")
    func containsFollowsAncestry() async throws {
        let repo = GitFixture(name: "release-tags-contains")
        await repo.initRepo(defaultBranch: "main")
        let first = try await repo.commit(filename: "a.txt", message: "first")
        let second = try await repo.commit(filename: "b.txt", message: "second")
        let reader = ReleaseTagReader()

        #expect(await reader.contains(first, tag: second, in: repo.path))
        #expect(await reader.contains(second, tag: second, in: repo.path))
        #expect(await !reader.contains(second, tag: first, in: repo.path))
        #expect(await !reader.contains("--not-a-commit", tag: second, in: repo.path))
    }
}
