import CryptoKit
import Domain
import Foundation
@testable import Repositories
import Testing

// landing/open-one-pull-request-per-repository#uncommitted-snapshot (OQ196 item 1): staged changes are uncommitted
// changes too. The snapshot's temporary index starts from a copy of the Worktree's own index, so a force-added
// ignored file is saved, and staged content the working copy no longer has is kept as an index commit.

@Suite("UncommittedSnapshot: staged changes", .serialized)
struct UncommittedSnapshotIndexTests {
    private let branch = FeatureBranch(name: "yh-staged")

    /// A main clone with `tracked.txt` ("one") and `.gitignore` (`*.log`), and a real `git worktree add` Worktree.
    private struct World: ~Copyable {
        let repo: GitFixture
        let worktree: String

        static func make(branch: String) async throws -> World {
            let repo = GitFixture(name: "snapshot-index-\(UUID().uuidString)")
            await repo.initRepo()
            try repo.writeFile(filename: ".gitignore", content: "*.log\n")
            _ = await repo.run(["add", ".gitignore"])
            _ = try await repo.commit(filename: "tracked.txt", content: "one", message: "initial")
            let path = repo.url.appending(component: "wt", directoryHint: .isDirectory).path(percentEncoded: false)
            try #require(await repo.run(["worktree", "add", "-b", branch, path]).isSuccess)
            return World(repo: repo, worktree: path)
        }

        func git(_ args: [String]) async -> String {
            await run(args).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func run(_ args: [String]) async -> GitCommandResult {
            await repo.git.run(["-C", worktree] + args)
        }

        func write(_ name: String, _ content: String) throws {
            try content.write(toFile: "\(worktree)/\(name)", atomically: true, encoding: .utf8)
        }

        func indexDigest() async throws -> String {
            let path = await git(["rev-parse", "--path-format=absolute", "--git-path", "index"])
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        func snapshot(_ branch: FeatureBranch) async -> UncommittedSnapshotResult {
            await UncommittedSnapshot(git: repo.git).snapshot(worktreePath: worktree, branch: branch)
        }
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a force-added ignored file is a staged change: it is saved, and the real index is untouched")
    func forceAddedIgnoredFileIsSaved() async throws {
        let world = try await World.make(branch: branch.name)
        try world.write("forced.log", "forced")
        try world.write("noise.log", "noise")
        try #require(await world.run(["add", "-f", "forced.log"]).isSuccess)
        let indexBefore = try await world.indexDigest()

        let result = await world.snapshot(branch)

        guard case .snapshotted(_, let commit, let modified, let untracked, _) = result else {
            Issue.record("Expected .snapshotted, got \(result)")
            return
        }
        #expect((modified, untracked) == (1, 0))
        let files = await world.git(["ls-tree", "-r", "--name-only", commit])
        #expect(files.split(separator: "\n").sorted() == [".gitignore", "forced.log", "tracked.txt"])
        #expect(await world.git(["show", "\(commit):forced.log"]) == "forced")
        #expect(try await world.indexDigest() == indexBefore)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("staged content the working copy no longer has is kept as an index commit, a parent of the snapshot")
    func stagedOnlyContentIsKept() async throws {
        let world = try await World.make(branch: branch.name)
        let head = await world.git(["rev-parse", "HEAD"])
        try world.write("tracked.txt", "staged")
        try #require(await world.run(["add", "tracked.txt"]).isSuccess)
        // The working copy goes back to HEAD's content: `MM`, and the only change is in the index.
        try world.write("tracked.txt", "one")
        let statusBefore = await world.git(["status", "--porcelain"])
        try #require(!statusBefore.isEmpty)
        let indexBefore = try await world.indexDigest()

        let result = await world.snapshot(branch)

        guard case .snapshotted(let ref, let commit, _, _, let chained) = result else {
            Issue.record("Expected .snapshotted, got \(result)")
            return
        }
        #expect(!chained)
        let parents = await world.git(["rev-list", "--parents", "-n", "1", commit])
            .split(separator: " ").dropFirst().map(String.init)
        #expect(parents.count == 2)
        #expect(parents.first == head)
        let indexCommit = try #require(parents.last)
        #expect(await world.git(["show", "\(indexCommit):tracked.txt"]) == "staged")
        #expect(await world.git(["show", "\(commit):tracked.txt"]) == "one")
        #expect(try await world.indexDigest() == indexBefore)
        #expect(await world.git(["status", "--porcelain"]) == statusBefore)

        // The same index and working tree again: already saved, nothing written.
        #expect(await world.snapshot(branch) == .alreadySnapshotted(ref: ref))
        #expect(await world.repo.revParse(ref) == commit)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a file rewritten with HEAD's own content leaves nothing to save and writes no ref")
    func nothingDiffersFromHeadIsClean() async throws {
        let world = try await World.make(branch: branch.name)
        // Only a stat change: status shows nothing, and no tree differs from HEAD's.
        try world.write("tracked.txt", "one")

        let result = await world.snapshot(branch)

        #expect(result == .clean)
        #expect(await world.repo.revParse(UncommittedSnapshot.ref(for: branch)) == nil)
    }
}
