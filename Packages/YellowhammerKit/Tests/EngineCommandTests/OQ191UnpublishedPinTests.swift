import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), items 6 and 9: before it releases a Worktree whose HEAD is not the recorded commit
// (descendant or not), the land Act pins that HEAD under a local ref outside `refs/heads/`. The pin is never
// pushed, does not block landing, and the report names it and the commits. The ref name is an engine detail, so
// the tests find the pin by the commit it points at. Spec at yellowhammer-spec f33bccf. Red cases are known
// issues until their behaviour lands.

/// The refs in `path` pointing at `commit`, other than branches, remote-tracking refs and the landed-tip pins.
private func pins(at commit: String, in path: String) async -> [String] {
    let listed = await oq191Git(path, ["for-each-ref", "--points-at", commit, "--format=%(refname)"]).stdout
    return listed.split(separator: "\n").map(String.init).filter {
        !$0.hasPrefix("refs/heads/") && !$0.hasPrefix("refs/remotes/") && !$0.hasPrefix("refs/yellowhammer/landed/")
    }
}

/// Every ref in `path` other than branches, remote-tracking refs and the landed-tip pins.
private func unexpectedRefs(in path: String) async -> [String] {
    let listed = await oq191Git(path, ["for-each-ref", "--format=%(refname)"]).stdout
    return listed.split(separator: "\n").map(String.init).filter {
        !$0.hasPrefix("refs/heads/") && !$0.hasPrefix("refs/remotes/") && !$0.hasPrefix("refs/yellowhammer/landed/")
    }
}

/// Given: backend's held Worktree has HEAD at `head` (on a detached HEAD) while its Feature Branch stays at the
/// Pushed Tip B1. `descending` makes `head` a commit after B1; otherwise a commit on B1's base that does not
/// descend from B1. When: land fires once, pushing B1, opening the pull request and releasing the Worktree.
private func releasedWithMovedHead(descending: Bool) async throws -> (world: OQ191LandWorld, head: String) {
    let world = try await OQ191LandWorld.make(withMobile: false)
    let backend = world["backend"]
    let detachAt = descending ? backend.tip : backend.base
    _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", detachAt])
    let head = try await backend.commitInWorktree("backend-unpublished.txt")
    try #require(await backend.branchHead() == backend.tip)

    let firing = await world.fire()
    try #require(firing.error == nil)
    try #require(await backend.remoteTip() == backend.tip)
    try #require(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
    return (world, head)
}

@Suite("OQ191 unpublished commits: pinned before release, never published", .serialized, .tags(.oq191))
struct OQ191UnpublishedPinTests {
    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: a Worktree HEAD after the Pushed Tip is pinned under a local ref outside refs/heads/",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func descendantHeadIsPinned() async throws {
        let (world, head) = try await releasedWithMovedHead(descending: true)

        await withKnownIssue("OQ191 item 6: a Worktree HEAD past the Pushed Tip is not pinned before release") {
            #expect(await !pins(at: head, in: world["backend"].clone.path).isEmpty)
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: the release report names the pin and the commits after the Pushed Tip",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func descendantHeadReportNamesThePin() async throws {
        let (world, head) = try await releasedWithMovedHead(descending: true)
        let backend = world["backend"]

        await withKnownIssue("OQ191 item 6: unpublished commits are not pinned or reported at release") {
            let pin = try #require(await pins(at: head, in: backend.clone.path).first)
            let reports = try #require(try await world.unpublishedReports("backend"))
            #expect(reports.contains {
                $0.contains(pin) && $0.contains(oq191Short(backend.tip)) && $0.contains(oq191Short(head))
            })
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 9: a rewritten Worktree HEAD that does not descend from the Pushed Tip is pinned too",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func rewrittenHeadIsPinned() async throws {
        let (world, head) = try await releasedWithMovedHead(descending: false)
        try #require(await oq191Git(world["backend"].clone.path, [
            "merge-base", "--is-ancestor", world["backend"].tip, head
        ]).isSuccess == false)

        await withKnownIssue("OQ191 item 9: a rewritten Worktree HEAD is not pinned before release") {
            #expect(await !pins(at: head, in: world["backend"].clone.path).isEmpty)
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 9: the report says a rewritten Worktree HEAD differs from the Pushed Tip and names both",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func rewrittenHeadIsReportedAsDiffering() async throws {
        let (world, head) = try await releasedWithMovedHead(descending: false)
        let tip = world["backend"].tip

        await withKnownIssue("OQ191 item 9: a rewritten Worktree HEAD is not reported") {
            let reports = try #require(try await world.unpublishedReports("backend"))
            #expect(reports.contains {
                $0.contains("differs") && $0.contains(oq191Short(tip)) && $0.contains(oq191Short(head))
            })
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: characterization: a Worktree HEAD at the Pushed Tip makes no pin and no report",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func exactHeadMakesNoPin() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let firing = await world.fire()
        try #require(firing.error == nil)
        try #require(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)

        #expect(await unexpectedRefs(in: world["backend"].clone.path).isEmpty)
        #expect(try await world.unpublishedReports("backend") ?? [] == [])
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: characterization: the unpublished Worktree HEAD is never on the remote",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unpublishedHeadIsNeverOnTheRemote() async throws {
        let (world, head) = try await releasedWithMovedHead(descending: true)
        let remote = world["backend"].remote.path

        #expect(await oq191Git(remote, ["for-each-ref", "--points-at", head]).stdout.isEmpty)
        #expect(await !oq191Git(remote, ["cat-file", "-e", "\(head)^{commit}"]).isSuccess)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 6: characterization: a Worktree with unpublished commits does not block landing",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unpublishedCommitsDoNotBlockLanding() async throws {
        let (world, _) = try await releasedWithMovedHead(descending: true)

        #expect(try world.isCycleLanded)
    }
}
