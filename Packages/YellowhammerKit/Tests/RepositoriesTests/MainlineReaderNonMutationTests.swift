import Domain
import Foundation
import Repositories
import Testing

@Suite("MainlineReader non-mutation tests")
struct MainlineReaderNonMutationTests {
    @Test("Mainline reads touch no working tree, index, ref, HEAD, or dirty files")
    func noMutationInvariant() async throws {
        let fixture = GitFixture(name: "mlr-no-mutation-9")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "clean.txt", content: "committed clean content")

        // Create dirty state in working tree
        let dirtyFileURL = fixture.url.appendingPathComponent("dirty.txt")
        try "untracked dirty content".write(to: dirtyFileURL, atomically: true, encoding: .utf8)

        let modifiedCleanURL = fixture.url.appendingPathComponent("clean.txt")
        try "modified in working tree".write(to: modifiedCleanURL, atomically: true, encoding: .utf8)

        let statusBefore = await fixture.run(["status", "--porcelain"]).stdout
        let headBefore = await fixture.run(["rev-parse", "HEAD"]).stdout
        let dirtyFileBefore = try String(contentsOf: dirtyFileURL, encoding: .utf8)
        let modifiedCleanBefore = try String(contentsOf: modifiedCleanURL, encoding: .utf8)

        let repo = Repo(name: "target", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [repo])
        let reader = MainlineReader()

        let read = try await reader.readFile(path: "clean.txt", repository: "target", in: repos)
        #expect(read.content == "committed clean content")

        _ = try await reader.transcribe(path: "clean.txt", repository: "target", in: repos)

        let statusAfter = await fixture.run(["status", "--porcelain"]).stdout
        let headAfter = await fixture.run(["rev-parse", "HEAD"]).stdout
        let dirtyFileAfter = try String(contentsOf: dirtyFileURL, encoding: .utf8)
        let modifiedCleanAfter = try String(contentsOf: modifiedCleanURL, encoding: .utf8)

        #expect(statusBefore == statusAfter)
        #expect(headBefore == headAfter)
        #expect(dirtyFileBefore == dirtyFileAfter)
        #expect(modifiedCleanBefore == modifiedCleanAfter)
    }
}
