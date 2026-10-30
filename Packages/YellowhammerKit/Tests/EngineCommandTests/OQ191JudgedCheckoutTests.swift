import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), the judged checkout: Verification judges a checkout of every touched repository at
// its recorded commit (the Pushed Tip, or the recorded base commit for a No-Pushed-Branch repository), never a
// held Worktree as it stands, and the record names what it judged. Spec at yellowhammer-spec f33bccf. Red
// cases are known issues until their behaviour lands.

/// Case 4. Given: backend and mobile pushed (mobile at B1), then Verification faulted; then B2 was committed in
/// mobile's held Worktree. When: land fires again.
private struct FaultedThenMoved {
    let world: OQ191LandWorld
    let commitB1: String
    let commitB2: String
    let second: OQ191Firing
}

private func faultedThenMoved() async throws -> FaultedThenMoved {
    let world = try await OQ191LandWorld.make()
    let mobile = world["mobile"]
    let first = await world.fire(verifier: .refuse)
    try #require(first.error != nil)
    try #require(try world.env.journal.featureVerification(cycleID: world.cycleID) == nil)
    try #require(await mobile.remoteTip() == mobile.tip)

    let commitB2 = try await mobile.commitInWorktree("mobile-after-fault.txt")
    try #require(await oq191RevParse(mobile.worktree) == commitB2)
    try #require(commitB2 != mobile.tip)

    let second = await world.fire()
    try #require(second.instruction != nil)
    return FaultedThenMoved(world: world, commitB1: mobile.tip, commitB2: commitB2, second: second)
}

@Suite("OQ191 judged checkout: Verification judges what was pushed", .serialized, .tags(.oq191))
struct OQ191JudgedCheckoutTests {
    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 2: after a Verification fault and a moved Worktree, the verifier is handed a checkout at B1",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func faultThenMoveJudgesThePushedTip() async throws {
        let retry = try await faultedThenMoved()
        let directory = try #require(retry.second.verifiedDirectories["mobile"])

        await withKnownIssue("OQ191 item 2: the verifier is handed the held Worktree as it stands") {
            #expect(await oq191RevParse(directory) == retry.commitB1)
        }
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "items 2, 3: after a Verification fault and a moved Worktree, the record names B1 as the judged commit",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func faultThenMoveRecordsThePushedTip() async throws {
        let retry = try await faultedThenMoved()
        try #require(try retry.world.env.journal.featureVerification(cycleID: retry.world.cycleID) != nil)

        withKnownIssue("OQ191 item 3: the Verification record names no judged commit") {
            let world = retry.world
            let judged = try #require(try OQ191Probe.judgedCheckouts(world.env.journal, cycleID: world.cycleID))
            #expect(judged.first { $0.repository == "mobile" }?.commit == retry.commitB1)
        }
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "item 2: after a Verification fault and a moved Worktree, B2 is reported as not published, naming B1 and B2",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func faultThenMoveReportsTheUnpublishedCommit() async throws {
        let retry = try await faultedThenMoved()
        let (shortB1, shortB2) = (oq191Short(retry.commitB1), oq191Short(retry.commitB2))

        await withKnownIssue("OQ191 item 2: a moved held Worktree is not reported as not published") {
            let reports = try #require(try await retry.world.unpublishedReports("mobile"))
            #expect(reports.contains { $0.contains(shortB1) && $0.contains(shortB2) })
        }
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 2: characterization: after a Verification fault and a moved Worktree, the Cycle lands",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func faultThenMoveDoesNotBlockLanding() async throws {
        let retry = try await faultedThenMoved()

        #expect(retry.second.error == nil)
        #expect(try retry.world.isCycleLanded)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#recorded-check-results
    @Test(
        "item 2: the verifier instruction names the Pushed Tip, not the head of the moved Feature Branch",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func instructionNamesThePushedTip() async throws {
        let retry = try await faultedThenMoved()
        let rendered = try #require(retry.second.instruction?.render())

        withKnownIssue("OQ191 item 2: the verifier instruction does not name the Pushed Tip") {
            #expect(rendered.contains(oq191Short(retry.commitB1)))
            #expect(!rendered.contains(oq191Short(retry.commitB2)))
        }
        withKnownIssue("OQ191 item 2: the verifier instruction still judges Check results against the branch head") {
            #expect(!rendered.contains("Resolve the head of each Feature Branch"))
        }
    }
}
