import CryptoKit
import Domain
import Foundation
@testable import Repositories
import Testing

// landing/open-one-pull-request-per-repository#uncommitted-snapshot (OQ196 item 1): the snapshot saves modified
// tracked files and untracked files git does not ignore under a local ref outside refs/heads/, and moves no branch,
// HEAD, index or file. Real git against fixture repositories, with a real `git worktree add` Worktree.

@Suite("UncommittedSnapshot: uncommitted changes saved under a local ref", .serialized)
struct UncommittedSnapshotTests {
    private let branch = FeatureBranch(name: "yh-feature")

    private struct World: ~Copyable {
        let repo: GitFixture
        let worktree: String
        let base: String

        static func make(branch: String) async throws -> World {
            let repo = GitFixture(name: "snapshot-\(UUID().uuidString)")
            await repo.initRepo()
            try repo.writeFile(filename: ".gitignore", content: "ignored.log\n")
            _ = await repo.run(["add", ".gitignore"])
            let base = try await repo.commit(filename: "tracked.txt", content: "one", message: "initial")
            let path = repo.url.appending(component: "wt", directoryHint: .isDirectory).path(percentEncoded: false)
            #expect(await repo.run(["worktree", "add", "-b", branch, path]).isSuccess)
            return World(repo: repo, worktree: path, base: base)
        }

        func git(_ args: [String]) async -> GitCommandResult {
            await repo.git.run(["-C", worktree] + args)
        }

        func write(_ name: String, _ content: String) throws {
            try content.write(toFile: "\(worktree)/\(name)", atomically: true, encoding: .utf8)
        }

        func dirty() throws {
            try write("tracked.txt", "two")
            try write("new.txt", "fresh")
            try write("ignored.log", "noise")
        }
    }

    private func indexDigest(_ world: borrowing World) async throws -> String {
        let located = await world.git(["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let path = located.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func take(_ world: borrowing World) async -> UncommittedSnapshotResult {
        await UncommittedSnapshot(git: world.repo.git).snapshot(worktreePath: world.worktree, branch: branch)
    }

    private func lines(_ result: GitCommandResult) -> [String] {
        result.stdout.split(whereSeparator: \.isNewline).map(String.init)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a modified tracked file and an untracked file are saved; an ignored file is not")
    func savesModifiedAndUntrackedNotIgnored() async throws {
        let world = try await World.make(branch: branch.name)
        try world.dirty()

        let result = await take(world)

        let ref = UncommittedSnapshot.ref(for: branch)
        guard case .snapshotted(let written, let commit, let modified, let untracked, let chained) = result else {
            Issue.record("Expected .snapshotted, got \(result)")
            return
        }
        #expect(written == ref)
        #expect(ref == "refs/yellowhammer/snapshot/yh-feature")
        #expect((modified, untracked, chained) == (1, 1, false))
        #expect(await world.repo.revParse(ref) == commit)
        let tree = await world.git(["ls-tree", "-r", "--name-only", commit])
        #expect(lines(tree).sorted() == [".gitignore", "new.txt", "tracked.txt"])
        #expect(await world.git(["show", "\(commit):tracked.txt"]).stdout == "two")
        #expect(await world.git(["rev-parse", "\(commit)^1"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == world.base)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("the snapshot moves no branch, HEAD, index or file")
    func movesNothing() async throws {
        let world = try await World.make(branch: branch.name)
        try world.dirty()
        let before = (
            tip: await world.repo.revParse("refs/heads/\(branch.name)"), head: await world.repo.revParse("HEAD"),
            worktreeHead: await world.git(["rev-parse", "HEAD"]).stdout,
            index: try await indexDigest(world), status: await world.git(["status", "--porcelain"]).stdout,
            tracked: try String(contentsOfFile: "\(world.worktree)/tracked.txt", encoding: .utf8),
            untracked: try String(contentsOfFile: "\(world.worktree)/new.txt", encoding: .utf8)
        )

        let result = await take(world)
        guard case .snapshotted = result else {
            Issue.record("Expected .snapshotted, got \(result)")
            return
        }

        #expect(await world.repo.revParse("refs/heads/\(branch.name)") == before.tip)
        #expect(await world.repo.revParse("HEAD") == before.head)
        #expect(await world.git(["rev-parse", "HEAD"]).stdout == before.worktreeHead)
        #expect(try await indexDigest(world) == before.index)
        #expect(await world.git(["status", "--porcelain"]).stdout == before.status)
        #expect(try String(contentsOfFile: "\(world.worktree)/tracked.txt", encoding: .utf8) == before.tracked)
        #expect(try String(contentsOfFile: "\(world.worktree)/new.txt", encoding: .utf8) == before.untracked)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a clean Worktree writes nothing")
    func cleanWritesNothing() async throws {
        let world = try await World.make(branch: branch.name)
        try world.write("ignored.log", "noise")

        let result = await take(world)

        #expect(result == .clean)
        #expect(await world.repo.revParse(UncommittedSnapshot.ref(for: branch)) == nil)
        #expect(await UncommittedSnapshot(git: world.repo.git).isDirty(worktreePath: world.worktree) == .clean)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("the same tree again is already snapshotted; a changed tree chains the earlier snapshot")
    func repeatAndChange() async throws {
        let world = try await World.make(branch: branch.name)
        try world.dirty()
        let snapshotter = UncommittedSnapshot(git: world.repo.git)
        guard case .snapshotted(let ref, let first, _, _, _) = await snapshotter.snapshot(
            worktreePath: world.worktree, branch: branch
        ) else {
            Issue.record("Expected .snapshotted")
            return
        }

        #expect(await snapshotter.snapshot(worktreePath: world.worktree, branch: branch)
            == .alreadySnapshotted(ref: ref))
        #expect(await world.repo.revParse(ref) == first)

        try world.write("more.txt", "more")
        guard case .snapshotted(_, let second, _, _, let chained) = await snapshotter.snapshot(
            worktreePath: world.worktree, branch: branch
        ) else {
            Issue.record("Expected a second .snapshotted")
            return
        }
        #expect(chained)
        #expect(second != first)
        #expect(await world.repo.revParse(ref) == second)
        let parents = await world.git(["rev-list", "--parents", "-n", "1", second]).stdout
            .split(whereSeparator: \.isWhitespace).map(String.init)
        #expect(parents == [second, world.base, first])
        #expect(await world.git(["merge-base", "--is-ancestor", first, second]).isSuccess)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a deleted tracked file counts as modified and is absent from the snapshot tree")
    func deletedFileIsModified() async throws {
        let world = try await World.make(branch: branch.name)
        try FileManager.default.removeItem(atPath: "\(world.worktree)/tracked.txt")

        let result = await take(world)

        guard case .snapshotted(_, let commit, let modified, let untracked, _) = result else {
            Issue.record("Expected .snapshotted, got \(result)")
            return
        }
        #expect((modified, untracked) == (1, 0))
        #expect(!lines(await world.git(["ls-tree", "-r", "--name-only", commit])).contains("tracked.txt"))
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a ref that cannot be written fails with git's reason, and writes no snapshot")
    func blockedRefFails() async throws {
        let world = try await World.make(branch: branch.name)
        try world.dirty()
        let ref = UncommittedSnapshot.ref(for: branch)
        #expect(await world.git(["update-ref", "\(ref)/x", world.base]).isSuccess)

        let result = await take(world)

        guard case .failed(let reason) = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(await world.repo.revParse(ref) == nil)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a runner's own environment is kept for the temporary index")
    func derivedRunnerKeepsEnvironment() async throws {
        let world = try await World.make(branch: branch.name)
        try world.dirty()
        var environment = ProcessInfo.processInfo.environment
        environment["YH_SENTINEL"] = "1"
        let runner = GitRunner(environment: environment)

        let result = await UncommittedSnapshot(git: runner).snapshot(worktreePath: world.worktree, branch: branch)

        guard case .snapshotted = result else {
            Issue.record("Expected .snapshotted, got \(result)")
            return
        }
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a directory that is not a git work tree is a failure to read, not clean")
    func notGitFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-notgit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = await UncommittedSnapshot().snapshot(
            worktreePath: directory.path(percentEncoded: false), branch: branch
        )

        guard case .failed = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
    }
}
