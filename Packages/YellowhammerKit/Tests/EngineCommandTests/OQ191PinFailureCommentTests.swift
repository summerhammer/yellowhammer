import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// Pin Failure Ruling, item 2 (agent ruling 2026-11-02, pending sponsor review): a pin or a non-git directory that
// keeps a Worktree held at the land Act posts a board comment naming the cause and a route out, and the release
// step's detail is that same text. Real git per repository; the assertions are on the board's comments, the
// landStep detail and the refs, never on a verdict, a push or a pull request body.

private let pinRef = "refs/yellowhammer/unpublished/\(landBranch.name)"

/// Makes `refs/yellowhammer/unpublished/<branch>` unwritable in `clone`: a ref below it makes the path a directory.
private func blockPin(in clone: String, at commit: String) async throws {
    try #require(await oq191Git(clone, ["update-ref", "\(pinRef)/blocker", commit]).isSuccess)
}

private func unblockPin(in clone: String) async {
    _ = await oq191Git(clone, ["update-ref", "-d", "\(pinRef)/blocker"])
}

/// Pushes the Feature Branch to the remote and records the Pushed Tip, removes the Worktree directory and moves the
/// branch in the main clone one commit past the Pushed Tip. Returns that commit.
private func pushAndMoveBranch(_ world: OQ191LandWorld) async throws -> String {
    let backend = world["backend"]
    _ = await oq191Git(
        backend.clone.path, ["push", "origin", "refs/heads/\(landBranch.name):refs/heads/\(landBranch.name)"]
    )
    try world.env.journal.recordPushedTip(
        cycleID: world.cycleID, repository: "backend", commit: backend.tip, runID: world.env.runID
    )
    try FileManager.default.removeItem(atPath: backend.worktree)
    let clone = backend.clone.path
    let filename = "extra-\(UUID().uuidString).txt"
    try "extra content".write(toFile: "\(clone)/\(filename)", atomically: true, encoding: .utf8)
    _ = await oq191Git(clone, ["checkout", "-b", "temp-move", backend.tip])
    _ = await oq191Git(clone, ["add", filename])
    _ = await oq191Git(clone, ["commit", "-m", "extra commit"])
    let commit = try #require(await oq191RevParse(clone))
    _ = await oq191Git(clone, ["checkout", "main"])
    _ = await oq191Git(clone, ["branch", "-D", "temp-move"])
    _ = await oq191Git(clone, ["update-ref", "refs/heads/\(landBranch.name)", commit])
    return commit
}

@Suite("OQ191 pin failure: board comment with a route out", .serialized, .tags(.oq191))
struct OQ191PinFailureCommentTests {
    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("(1) a failed pin of a moved Worktree HEAD keeps it held, and the comment is the landStep detail")
    func failedHeadPinPostsCommentWithRouteOut() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", backend.tip])
        try await backend.commitInWorktree("backend-unpublished.txt")
        try await blockPin(in: backend.clone.path, at: backend.tip)

        let firing = await world.fire()
        try #require(firing.error == nil)

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        let detail = try #require(step.detail)
        for issue in ["FEAT-1", "BACK-1"] {
            let comments = await world.heldWorktreeComments("backend", on: issue)
            #expect(comments == [detail])
        }
        #expect(detail.hasPrefix("Not landed: the Worktree's HEAD in `backend` could not be pinned before release."))
        #expect(detail.contains("Cause: git reported: "))
        #expect(detail.contains("Route out: fix what git names"))
        #expect(detail.contains("put the Worktree's HEAD back at the recorded commit \(oq191Short(backend.tip))"))
        #expect(try !world.isCycleLanded)

        _ = await world.fire()
        for issue in ["FEAT-1", "BACK-1"] {
            #expect(await world.heldWorktreeComments("backend", on: issue).count == 1)
        }
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("(2) putting the Worktree's HEAD back at the recorded commit releases it with no pin and no new comment")
    func headPutBackReleasesWithoutPin() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", backend.tip])
        try await backend.commitInWorktree("backend-unpublished.txt")
        try await blockPin(in: backend.clone.path, at: backend.tip)
        _ = await world.fire()
        try #require(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .failed)

        // The blocker stays: putting HEAD back is enough on its own, so no pin is attempted.
        try #require(await oq191Git(backend.worktree, ["reset", "--hard", backend.tip]).isSuccess)
        let firing = await world.fire()
        try #require(firing.error == nil)

        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        #expect(await oq191RevParse(backend.clone.path, pinRef) == nil)
        #expect(await oq191RevParse(backend.clone.path, "\(pinRef)/blocker") == backend.tip)
        for issue in ["FEAT-1", "BACK-1"] {
            #expect(await world.heldWorktreeComments("backend", on: issue).count == 1)
        }
        #expect(try world.isCycleLanded)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("(1) a pin that then fails for a different reason posts a second comment naming the new reason")
    func differentReasonPostsSecondComment() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", backend.tip])
        try await backend.commitInWorktree("backend-unpublished.txt")
        try await blockPin(in: backend.clone.path, at: backend.tip)
        _ = await world.fire()
        try #require(await world.heldWorktreeComments("backend", on: "FEAT-1").count == 1)

        // A stale lock file instead of the directory conflict: git refuses the pin with a different reason.
        await unblockPin(in: backend.clone.path)
        let lockPath = "\(backend.clone.path)/.git/\(pinRef).lock"
        try FileManager.default.createDirectory(
            atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try "".write(toFile: lockPath, atomically: true, encoding: .utf8)
        _ = await world.fire()
        _ = await world.fire()

        let comments = await world.heldWorktreeComments("backend", on: "FEAT-1")
        #expect(comments.count == 2)
        #expect(comments.count == 2 && comments[0] != comments[1])
        let detail = try #require(world.env.releaseWorktreeStep(repository: "backend")?.detail)
        #expect(comments.last == detail)
        #expect(await oq191RevParse(backend.clone.path, pinRef) == nil)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("(3) a non-git directory posts the not-a-work-tree comment once, naming the pin, as the landStep detail")
    func nonGitDirectoryPostsCommentOnce() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        let branchCommit = try await pushAndMoveBranch(world)
        try FileManager.default.createDirectory(atPath: backend.worktree, withIntermediateDirectories: true)

        _ = await world.fire()
        _ = await world.fire()

        #expect(await oq191RevParse(backend.clone.path, pinRef) == branchCommit)
        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        let detail = try #require(step.detail)
        for issue in ["FEAT-1", "BACK-1"] {
            #expect(await world.heldWorktreeComments("backend", on: issue) == [detail])
        }
        #expect(detail.hasPrefix("Not landed: the Worktree directory for `backend` at `"))
        #expect(detail.contains("is not a git work tree"))
        #expect(detail.contains("Its Feature Branch is pinned at `\(pinRef)`."))
        #expect(detail.contains("repair the directory so git can read it, or remove it"))
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("(3) a non-git directory whose branch needs no pin posts the comment without a pin ref")
    func nonGitDirectoryWithoutPinNamesNoRef() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        try FileManager.default.removeItem(atPath: "\(backend.worktree)/.git")

        _ = await world.fire()

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        let detail = try #require(step.detail)
        #expect(await world.heldWorktreeComments("backend", on: "FEAT-1") == [detail])
        #expect(detail.contains("is not a git work tree"))
        #expect(!detail.contains("Its Feature Branch is pinned"))
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("(4) a gone directory whose Feature Branch does not resolve is released, saying nothing was pinned")
    func goneDirectoryAbsentBranchSaysNothingPinned() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        try FileManager.default.removeItem(atPath: backend.worktree)
        _ = await oq191Git(backend.clone.path, ["worktree", "prune"])
        _ = await oq191Git(backend.clone.path, ["branch", "-D", landBranch.name])

        let firing = await world.fire()
        try #require(firing.error == nil)

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .completed)
        #expect(step.detail?.hasPrefix("nothing was pinned: the Feature Branch") == true)
        #expect(await world.heldWorktreeComments("backend", on: "FEAT-1").isEmpty)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("(5) a gone directory's moved branch is pinned and stays reachable after the branch is deleted")
    func goneDirectoryPinSurvivesBranchDeletion() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        let branchCommit = try await pushAndMoveBranch(world)

        let firing = await world.fire()
        try #require(firing.error == nil)
        try #require(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)

        _ = await oq191Git(backend.clone.path, ["worktree", "prune"])
        try #require(await oq191Git(backend.clone.path, ["branch", "-D", landBranch.name]).isSuccess)
        #expect(await oq191RevParse(backend.clone.path, pinRef) == branchCommit)
        #expect(await oq191RevParse(backend.clone.path, "\(branchCommit)^{commit}") == branchCommit)
    }
}
