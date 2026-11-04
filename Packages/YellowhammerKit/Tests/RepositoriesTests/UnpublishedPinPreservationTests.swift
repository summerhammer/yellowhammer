import Domain
import Foundation
import Repositories
import Testing

@Suite("Unpublished pins preserve earlier commits")
struct UnpublishedPinPreservationTests {
    private let branch = FeatureBranch(name: "yh-preserved")

    enum Writer: CaseIterable {
        case head
        case branch
    }

    private func pin(
        _ writer: Writer, repo: borrowing GitFixture, recordedCommit: String
    ) async -> UnpublishedHeadPinResult {
        let pin = UnpublishedHeadPin(git: repo.git)
        if writer == .head {
            return await pin.pinUnpublishedHead(
                worktreePath: repo.path, recordedCommit: recordedCommit, branch: branch
            )
        }
        switch await pin.pinFeatureBranch(
            repositoryPath: repo.path, recordedCommit: recordedCommit, branch: branch
        ) {
        case .pinned(let ref, let relation): return .pinned(ref: ref, relation: relation)
        case .alreadyPinned(let ref): return .alreadyPinned(ref: ref)
        case .notNeeded: return .notNeeded
        case .failed(let reason): return .failed(reason: reason)
        case .absent: return .failed(reason: "test branch unexpectedly absent")
        }
    }

    @Test("both writers safely advance an existing pin to a descendant", arguments: Writer.allCases)
    func advancesToDescendant(writer: Writer) async throws {
        let repo = GitFixture()
        await repo.initRepo()
        let base = try await repo.commit(filename: "base.txt")
        try #require(await repo.run(["checkout", "-b", branch.name]).isSuccess)
        let first = try await repo.commit(filename: "first.txt")
        let ref = UnpublishedHeadPin.ref(for: branch)
        #expect(await pin(writer, repo: repo, recordedCommit: base) == .pinned(
            ref: ref, relation: .after(commits: 1, head: first)
        ))
        let second = try await repo.commit(filename: "second.txt")

        #expect(await pin(writer, repo: repo, recordedCommit: base) == .pinned(
            ref: ref, relation: .after(commits: 2, head: second)
        ))
        #expect(await repo.revParse(ref) == second)
        #expect(await pin(writer, repo: repo, recordedCommit: base) == .alreadyPinned(ref: ref))
    }

    @Test("both writers refuse a backward or divergent pin", arguments: Writer.allCases, [false, true])
    func refusesLossOfEarlierCommit(writer: Writer, divergent: Bool) async throws {
        let repo = GitFixture()
        await repo.initRepo()
        let base = try await repo.commit(filename: "base.txt")
        try #require(await repo.run(["checkout", "-b", branch.name]).isSuccess)
        let first = try await repo.commit(filename: "first.txt")
        let pinned = try await repo.commit(filename: "pinned.txt")
        let ref = UnpublishedHeadPin.ref(for: branch)
        #expect(await pin(writer, repo: repo, recordedCommit: base) == .pinned(
            ref: ref, relation: .after(commits: 2, head: pinned)
        ))
        try #require(await repo.run(["reset", "--hard", divergent ? base : first]).isSuccess)
        let proposed = divergent ? try await repo.commit(filename: "rewritten.txt") : first

        #expect(await pin(writer, repo: repo, recordedCommit: base) == .failed(
            reason: "already pinned at \(pinned), which is not an ancestor of \(proposed)"
        ))
        #expect(await repo.revParse(ref) == pinned)
    }

    @Test("a gone detached Worktree's HEAD pin survives the older main-clone branch pin")
    func detachedHeadSurvivesGoneWorktree() async throws {
        let repo = GitFixture()
        let layout = GitFixture()
        await repo.initRepo()
        let base = try await repo.commit(filename: "base.txt")
        try #require(await repo.run(["checkout", "-b", branch.name]).isSuccess)
        let branchTip = try await repo.commit(filename: "branch.txt")
        let worktree = layout.url.appending(component: "detached").path(percentEncoded: false)
        try #require(await repo.run(["worktree", "add", "--detach", worktree, branchTip]).isSuccess)
        try "unpublished".write(toFile: "\(worktree)/unpublished.txt", atomically: true, encoding: .utf8)
        try #require(await repo.git.run(["-C", worktree, "add", "unpublished.txt"]).isSuccess)
        try #require(await repo.git.run(["-C", worktree, "commit", "-m", "detached work"]).isSuccess)
        let head = await repo.git.run(["-C", worktree, "rev-parse", "HEAD"])
        try #require(head.isSuccess)
        let detached = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = UnpublishedHeadPin(git: repo.git)
        let ref = UnpublishedHeadPin.ref(for: branch)
        #expect(await pin.pinUnpublishedHead(
            worktreePath: worktree, recordedCommit: base, branch: branch
        ) == .pinned(ref: ref, relation: .after(commits: 2, head: detached)))
        try FileManager.default.removeItem(atPath: worktree)

        #expect(await pin.pinFeatureBranch(
            repositoryPath: repo.path, recordedCommit: base, branch: branch
        ) == .failed(reason: "already pinned at \(detached), which is not an ancestor of \(branchTip)"))
        #expect(await repo.revParse(ref) == detached)
    }

    @Test("git refuses a stale old value and an absent-ref expectation after another writer creates the pin")
    func compareAndSwapRefusesStaleExpectation() async throws {
        let repo = GitFixture()
        await repo.initRepo()
        let base = try await repo.commit(filename: "base.txt")
        let first = try await repo.commit(filename: "first.txt")
        let second = try await repo.commit(filename: "second.txt")
        let ref = UnpublishedHeadPin.ref(for: branch)
        try #require(await repo.run(["update-ref", ref, first, ""]).isSuccess)
        try #require(await repo.run(["update-ref", ref, second, first]).isSuccess)

        #expect(await !repo.run(["update-ref", ref, base, first]).isSuccess)
        #expect(await repo.revParse(ref) == second)
        #expect(await !repo.run(["update-ref", ref, base, ""]).isSuccess)
        #expect(await repo.revParse(ref) == second)
    }
}
