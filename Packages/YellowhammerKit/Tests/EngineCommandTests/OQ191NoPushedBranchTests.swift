import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), item 5: a repository with the No-Pushed-Branch Outcome is judged at its recorded
// base commit (`feature_base.base_commit`), never the base ref resolved again, and is marked "no pushed
// branch". If its held Worktree moved past that base, the newer commits are reported as not published and do
// not block landing. Spec at yellowhammer-spec f33bccf. Red cases are known issues until their behaviour lands.

/// Given: mobile has the No-Pushed-Branch Outcome at base M0, and its mainline then moved to M1 (pushed, so
/// `refs/remotes/origin/main` is at M1). Returns the world and M1.
private func noPushedBranchAfterMainlineMoved() async throws -> (world: OQ191LandWorld, mainlineM1: String) {
    let world = try await OQ191LandWorld.make(noPushedBranch: ["mobile"])
    let mobile = world["mobile"]
    let mainlineM1 = try await mobile.clone.commit(filename: "mainline.txt", content: "moved", message: "mainline")
    try #require(await mobile.clone.run(["push", "origin", "main"]).isSuccess)
    try #require(await mobile.clone.revParse("refs/remotes/origin/main") == mainlineM1)
    try #require(mainlineM1 != mobile.base)
    try #require(await mobile.branchHead() == mobile.base)
    return (world, mainlineM1)
}

/// The same, with mobile's held Worktree then moved past its base, W1, on a detached HEAD: the Feature Branch
/// stays at the base, so its push still has no completed work.
private func noPushedBranchWithMovedWorktree() async throws -> (world: OQ191LandWorld, worktreeW1: String) {
    let (world, _) = try await noPushedBranchAfterMainlineMoved()
    let mobile = world["mobile"]
    _ = await oq191Git(mobile.worktree, ["checkout", "--quiet", "--detach"])
    let worktreeW1 = try await mobile.commitInWorktree("mobile-past-base.txt")
    try #require(await mobile.branchHead() == mobile.base)
    try #require(worktreeW1 != mobile.base)
    return (world, worktreeW1)
}

private func requireNoPushedBranchOutcome(_ world: OQ191LandWorld) throws {
    #expect(try world.env.journal.noPushedBranchRepositories(featureID: world.feature.id) == ["mobile"])
    #expect(try world.env.journal.pushedRepositories(featureID: world.feature.id) == ["backend"])
}

@Suite("OQ191 No-Pushed-Branch repository: judged at its recorded base commit", .tags(.oq191))
struct OQ191NoPushedBranchTests {
    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 5: characterization: a No-Pushed-Branch repository is judged at its recorded base after mainline moved",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func judgedAtTheRecordedBase() async throws {
        let (world, mainlineM1) = try await noPushedBranchAfterMainlineMoved()

        let firing = await world.fire()
        try requireNoPushedBranchOutcome(world)

        let directory = try #require(firing.verifiedDirectories["mobile"])
        #expect(await oq191RevParse(directory) == world["mobile"].base)
        #expect(await oq191RevParse(directory) != mainlineM1)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 5: the record names the recorded base commit as judged, marked no pushed branch",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func recordNamesTheBaseMarkedNoPushedBranch() async throws {
        let (world, _) = try await noPushedBranchAfterMainlineMoved()
        let firing = await world.fire()
        try #require(firing.error == nil)
        try requireNoPushedBranchOutcome(world)
        let expected = OQ191JudgedCheckout(
            repository: "mobile", commit: world["mobile"].base, kind: .heldWorktree, noPushedBranch: true
        )

        withKnownIssue("OQ191 item 5: the record names no judged commit for a No-Pushed-Branch repository") {
            let judged = try #require(try OQ191Probe.judgedCheckouts(world.env.journal, cycleID: world.cycleID))
            #expect(judged.first { $0.repository == "mobile" } == expected)
        }
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 5: a held Worktree moved past its base is not judged; the verifier gets a checkout at the base",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedWorktreeIsJudgedAtTheBase() async throws {
        let (world, _) = try await noPushedBranchWithMovedWorktree()

        let firing = await world.fire()
        try requireNoPushedBranchOutcome(world)
        let directory = try #require(firing.verifiedDirectories["mobile"])

        await withKnownIssue("OQ191 item 5: the verifier is handed the held Worktree as it stands") {
            #expect(await oq191RevParse(directory) == world["mobile"].base)
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 5: commits past the recorded base are reported as not published, naming both commits",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedWorktreeIsReportedNotPublished() async throws {
        let (world, worktreeW1) = try await noPushedBranchWithMovedWorktree()
        _ = await world.fire()
        try requireNoPushedBranchOutcome(world)
        let (shortBase, shortW1) = (oq191Short(world["mobile"].base), oq191Short(worktreeW1))

        await withKnownIssue("OQ191 item 5: commits past the recorded base are not reported as not published") {
            let reports = try #require(try await world.unpublishedReports("mobile"))
            #expect(reports.contains { $0.contains(shortBase) && $0.contains(shortW1) })
        }
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 5: characterization: a No-Pushed-Branch Worktree moved past its base does not block landing",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedWorktreeDoesNotBlockLanding() async throws {
        let (world, _) = try await noPushedBranchWithMovedWorktree()

        let firing = await world.fire()
        try requireNoPushedBranchOutcome(world)

        #expect(firing.error == nil)
        #expect(try world.isCycleLanded)
    }
}
