import Foundation
@testable import Repositories
import Testing

@Suite("GitHubRepositorySlug (P10.4)")
struct GitHubRepositorySlugTests {
    @Test("https URL, with and without .git", arguments: [
        "https://github.com/summerhammer/yellowhammer",
        "https://github.com/summerhammer/yellowhammer.git"
    ])
    func httpsURL(_ url: String) {
        let expected = GitHubRepositorySlug(owner: "summerhammer", repository: "yellowhammer")
        #expect(GitHubRepositorySlug.parse(url) == expected)
    }

    @Test("scp-style git@github.com URL, with and without .git", arguments: [
        "git@github.com:summerhammer/yellowhammer",
        "git@github.com:summerhammer/yellowhammer.git"
    ])
    func scpStyleURL(_ url: String) {
        let expected = GitHubRepositorySlug(owner: "summerhammer", repository: "yellowhammer")
        #expect(GitHubRepositorySlug.parse(url) == expected)
    }

    @Test("ssh:// URL, with and without .git", arguments: [
        "ssh://git@github.com/summerhammer/yellowhammer",
        "ssh://git@github.com/summerhammer/yellowhammer.git"
    ])
    func sshURL(_ url: String) {
        let expected = GitHubRepositorySlug(owner: "summerhammer", repository: "yellowhammer")
        #expect(GitHubRepositorySlug.parse(url) == expected)
    }

    @Test("A non-GitHub host does not parse")
    func nonGitHubHost() {
        #expect(GitHubRepositorySlug.parse("https://gitlab.com/o/r.git") == nil)
    }

    @Test("A malformed value does not parse")
    func malformed() {
        #expect(GitHubRepositorySlug.parse("not a url") == nil)
        #expect(GitHubRepositorySlug.parse("") == nil)
        #expect(GitHubRepositorySlug.parse("https://github.com/onlyowner") == nil)
    }

    @Test("Resolving from a real repository's origin remote")
    func resolveFromFixtureRepo() async {
        let repo = GitFixture(name: "slug-\(UUID().uuidString)")
        await repo.initRepo()
        _ = await repo.run(["remote", "add", "origin", "git@github.com:summerhammer/yellowhammer.git"])

        let resolver = GitHubRepositorySlugResolver()
        let slug = await resolver.resolve(path: repo.path)
        #expect(slug == GitHubRepositorySlug(owner: "summerhammer", repository: "yellowhammer"))
    }

    @Test("Resolving with no origin remote configured returns nil")
    func resolveNoRemote() async {
        let repo = GitFixture(name: "slug-noremote-\(UUID().uuidString)")
        await repo.initRepo()

        let resolver = GitHubRepositorySlugResolver()
        let slug = await resolver.resolve(path: repo.path)
        #expect(slug == nil)
    }
}
