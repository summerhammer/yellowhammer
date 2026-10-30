import Domain
import Foundation
import Testing

@testable import Repositories

// OQ191 (yellowhammer#708): the local git operations behind the remote tip check (item 4), checkout reuse (items
// 7 and 8) and the unpublished-commits pin (items 6 and 9), against real temporary repositories: a main clone
// whose `origin` is a bare repository, and a held Worktree made with `git worktree add`. Spec at
// yellowhammer-spec f33bccf. Red cases are known issues until their behaviour lands.

private let branch = FeatureBranch(name: "yh-proj-feat")

/// A main clone on `main` (at `base`), a bare `origin`, and a Worktree of the Feature Branch one commit past
/// `base` (at `tip`), not yet pushed.
private struct OQ191GitWorld: ~Copyable {
    let clone: GitFixture
    let remote: GitFixture
    let layout: GitFixture
    let base: String
    let tip: String

    var worktree: String { layout.url.appending(component: "backend").path(percentEncoded: false) }

    static func make() async throws -> OQ191GitWorld {
        let clone = GitFixture(name: "oq191-clone-\(UUID().uuidString)")
        await clone.initRepo()
        let base = try await clone.commit(filename: "README.md", message: "initial")
        let remote = GitFixture(name: "oq191-remote-\(UUID().uuidString)")
        await remote.initRepo(bare: true)
        await clone.addRemote(url: remote.path)
        #expect(await clone.run(["push", "origin", "main"]).isSuccess)
        let layout = GitFixture(name: "oq191-layout-\(UUID().uuidString)")
        let worktree = layout.url.appending(component: "backend").path(percentEncoded: false)
        #expect(await clone.run(["worktree", "add", "-b", branch.name, worktree]).isSuccess)
        try "work".write(toFile: "\(worktree)/work.txt", atomically: true, encoding: .utf8)
        _ = await clone.git.run(["-C", worktree, "add", "work.txt"])
        _ = await clone.git.run(["-C", worktree, "commit", "-m", "work"])
        let tip = try #require(await clone.revParse("refs/heads/\(branch.name)"))
        return OQ191GitWorld(clone: clone, remote: remote, layout: layout, base: base, tip: tip)
    }

    func git(_ args: [String]) async -> GitCommandResult {
        await clone.git.run(["-C", worktree] + args)
    }

    /// Commits a new file in the Worktree; returns the new HEAD.
    func commitInWorktree(_ filename: String) async throws -> String {
        try UUID().uuidString.write(toFile: "\(worktree)/\(filename)", atomically: true, encoding: .utf8)
        _ = await git(["add", filename])
        _ = await git(["commit", "-m", filename])
        return try #require(await clone.git.run(["-C", worktree, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func pushBranch() async -> Bool {
        await clone.run(["push", "origin", "refs/heads/\(branch.name):refs/heads/\(branch.name)"]).isSuccess
    }
}

/// How a Worktree is made not exact and clean.
enum OQ191WorktreeDirt: String, CaseIterable, CustomTestStringConvertible {
    case untrackedFile
    case modifiedFile
    case otherHead

    var testDescription: String { rawValue }
}

@Suite("OQ191 git operations: remote tip, checkout reuse, unpublished pin", .tags(.oq191))
struct OQ191GitOperationsTests {
    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: the remote tip reads the commit the remote Feature Branch is at",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteTipAtThePushedCommit() async throws {
        let world = try await OQ191GitWorld.make()
        try #require(await world.pushBranch())

        #expect(await OQ191Probe.remoteTip(branch: branch, repositoryPath: world.clone.path) == .at(world.tip))
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: the remote tip reads another commit when the remote branch moved",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteTipAtAnotherCommit() async throws {
        let world = try await OQ191GitWorld.make()
        try #require(await world.pushBranch())
        try #require(await world.remote.run(["update-ref", "refs/heads/\(branch.name)", world.base]).isSuccess)

        #expect(await OQ191Probe.remoteTip(branch: branch, repositoryPath: world.clone.path) == .at(world.base))
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: the remote tip reads absent when the remote has no Feature Branch",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteTipAbsent() async throws {
        let world = try await OQ191GitWorld.make()
        try #require(await world.remote.revParse("refs/heads/\(branch.name)") == nil)

        #expect(await OQ191Probe.remoteTip(branch: branch, repositoryPath: world.clone.path) == .absent)
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: the remote tip reads unreadable when the remote cannot be read",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteTipUnreadable() async throws {
        let world = try await OQ191GitWorld.make()
        try #require(await world.pushBranch())
        try #require(await world.clone.run(["remote", "set-url", "origin", "\(world.remote.path)missing"]).isSuccess)
        try #require(await !world.clone.run(["ls-remote", "origin"]).isSuccess)

        #expect(await OQ191Probe.remoteTip(branch: branch, repositoryPath: world.clone.path) == .unreadable)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 7: a Worktree at its recorded commit with only ignored files is exact and clean",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func ignoredFilesAreExactAndClean() async throws {
        let world = try await OQ191GitWorld.make()
        try "build/\n".write(toFile: "\(world.clone.path)/.git/info/exclude", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: "\(world.worktree)/build", withIntermediateDirectories: true)
        try "output".write(toFile: "\(world.worktree)/build/output.o", atomically: true, encoding: .utf8)
        try #require(await world.git(["status", "--porcelain"]).stdout.isEmpty)

        #expect(await OQ191Probe.isExactAndClean(worktreePath: world.worktree, recordedCommit: world.tip) == true)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 7: a Worktree with an untracked file, a modification or another HEAD is not exact and clean",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708"),
        arguments: OQ191WorktreeDirt.allCases
    )
    func dirtyWorktreeIsNotExactAndClean(dirt: OQ191WorktreeDirt) async throws {
        let world = try await OQ191GitWorld.make()
        switch dirt {
        case .untrackedFile:
            try "scratch".write(toFile: "\(world.worktree)/untracked.txt", atomically: true, encoding: .utf8)
        case .modifiedFile:
            try "edited".write(toFile: "\(world.worktree)/work.txt", atomically: true, encoding: .utf8)
        case .otherHead:
            _ = await world.git(["checkout", "--quiet", "--detach", world.base])
        }

        #expect(await OQ191Probe.isExactAndClean(worktreePath: world.worktree, recordedCommit: world.tip) == false)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "items 6, 9: HEAD is at, after, or differs from the recorded commit",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func headRelationToTheRecordedCommit() async throws {
        let world = try await OQ191GitWorld.make()
        let atTip = await OQ191Probe.headRelation(worktreePath: world.worktree, recordedCommit: world.tip)
        _ = try await world.commitInWorktree("one.txt")
        let after = try await world.commitInWorktree("two.txt")
        let twoAfter = await OQ191Probe.headRelation(worktreePath: world.worktree, recordedCommit: world.tip)
        _ = await world.git(["checkout", "--quiet", "--detach", world.base])
        let rewritten = try await world.commitInWorktree("rewritten.txt")
        let differs = await OQ191Probe.headRelation(worktreePath: world.worktree, recordedCommit: world.tip)

        #expect(atTip == .atRecordedCommit)
        #expect(twoAfter == .after(commits: 2, head: after))
        #expect(differs == .differs(head: rewritten))
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: a HEAD after the recorded commit is pinned outside refs/heads/, and the pin is not pushed",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func descendantHeadIsPinnedLocally() async throws {
        let world = try await OQ191GitWorld.make()
        try #require(await world.pushBranch())
        let head = try await world.commitInWorktree("unpublished.txt")

        let result = await OQ191Probe.pinUnpublishedHead(
            worktreePath: world.worktree, recordedCommit: world.tip, branch: branch
        )

        guard case .pinned(let ref) = result else {
            Issue.record("expected a pin, got \(String(describing: result))")
            return
        }
        #expect(!ref.hasPrefix("refs/heads/"))
        #expect(await world.clone.revParse(ref) == head)
        #expect(await world.remote.revParse(ref) == nil)
        #expect(await !world.remote.run(["cat-file", "-e", "\(head)^{commit}"]).isSuccess)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 9: a rewritten HEAD that does not descend from the recorded commit is pinned too",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func rewrittenHeadIsPinnedLocally() async throws {
        let world = try await OQ191GitWorld.make()
        _ = await world.git(["checkout", "--quiet", "--detach", world.base])
        let head = try await world.commitInWorktree("rewritten.txt")

        let result = await OQ191Probe.pinUnpublishedHead(
            worktreePath: world.worktree, recordedCommit: world.tip, branch: branch
        )

        guard case .pinned(let ref) = result else {
            Issue.record("expected a pin, got \(String(describing: result))")
            return
        }
        #expect(await world.clone.revParse(ref) == head)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: a HEAD at the recorded commit needs no pin",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func exactHeadNeedsNoPin() async throws {
        let world = try await OQ191GitWorld.make()
        let refsBefore = await world.clone.run(["for-each-ref", "--format=%(refname)"]).stdout

        let result = await OQ191Probe.pinUnpublishedHead(
            worktreePath: world.worktree, recordedCommit: world.tip, branch: branch
        )

        #expect(result == .notNeeded)
        #expect(await world.clone.run(["for-each-ref", "--format=%(refname)"]).stdout == refsBefore)
    }
}
