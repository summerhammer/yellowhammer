import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), the publication retry: a retried land firing publishes what the first firing
// pushed. It never pushes a successfully pushed branch again and never judges it again; a refused push is
// still retried. Spec at yellowhammer-spec f33bccf. Red cases are known issues until their behaviour lands.

/// Case 1's world after both firings. Given: backend and mobile pushed (mobile at B1) and Verification is
/// recorded; mobile's pull request was refused; then mobile's Feature Branch moved to B2 in its held Worktree.
/// When: land fires again.
private struct MovedBranchRetry {
    let world: OQ191LandWorld
    let commitB1: String
    let commitB2: String
    let first: OQ191Firing
    let second: OQ191Firing
}

private func movedBranchRetry() async throws -> MovedBranchRetry {
    let world = try await OQ191LandWorld.make(refusingPullRequest: ["mobile"])
    let mobile = world["mobile"]
    let first = await world.fire()
    #expect(first.error == nil)
    try #require(try world.env.journal.featureVerification(cycleID: world.cycleID) != nil)
    try #require(await mobile.remoteTip() == mobile.tip)
    #expect(try !world.isCycleLanded)
    #expect(try heldWorktreeIDs(world.env.journal, featureID: world.feature.id)["mobile"] == true)

    let commitB2 = try await mobile.commitInWorktree("mobile-after-push.txt")
    try #require(await mobile.branchHead() == commitB2)
    try #require(commitB2 != mobile.tip)
    try #require(await mobile.remoteTip() == mobile.tip)

    let second = await world.fire()
    return MovedBranchRetry(world: world, commitB1: mobile.tip, commitB2: commitB2, first: first, second: second)
}

/// Case 2's world after both firings: as case 1, without the move. Mobile's pull request was refused, and land
/// fires again.
private struct UnchangedRetry {
    let world: OQ191LandWorld
    let first: OQ191Firing
    let second: OQ191Firing
}

private func unchangedRetry() async throws -> UnchangedRetry {
    let world = try await OQ191LandWorld.make(refusingPullRequest: ["mobile"])
    let first = await world.fire()
    #expect(first.error == nil)
    try #require(try world.env.journal.featureVerification(cycleID: world.cycleID) != nil)
    #expect(try !world.isCycleLanded)
    let second = await world.fire()
    return UnchangedRetry(world: world, first: first, second: second)
}

@Suite("OQ191 publication retry: the retry publishes what was pushed", .serialized, .tags(.oq191))
struct OQ191PublicationRetryTests {
    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: a retry after the branch moved does not call the push seam for that branch",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedBranchIsNotPushedAgain() async throws {
        let retry = try await movedBranchRetry()

        #expect(retry.world.pushCalls("mobile") == 1)
        let remoteTip = await retry.world["mobile"].remoteTip()
        #expect(remoteTip == retry.commitB1)
    }

    // feature-authoring/stories/select-the-next-feature.md#pushed-tip
    @Test(
        "item 2: a retry after the branch moved keeps the recorded Pushed Tip at B1",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedBranchKeepsThePushedTip() async throws {
        let retry = try await movedBranchRetry()

        let world = retry.world
        let tip = try OQ191Probe.pushedTip(world.env.journal, cycleID: world.cycleID, repository: "mobile")
        #expect(tip == retry.commitB1)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: characterization: a retry after the branch moved does not run Verification again",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedBranchIsNotJudgedAgain() async throws {
        let retry = try await movedBranchRetry()

        #expect(retry.first.dispatch.requests.count == 1)
        #expect(retry.second.dispatch.requests.isEmpty)
        #expect(try retry.world.env.journal.events(ofType: .featureVerified).count == 1)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: a retry after the branch moved opens the pull request with the remote branch at B1",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedBranchPullRequestOpensAtThePushedTip() async throws {
        let retry = try await movedBranchRetry()

        let opened = await retry.world.publication.opened("mobile")
        #expect(opened == [OQ191Publication.Opened(repository: "mobile", remoteTip: retry.commitB1)])
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test(
        "items 1, 9: a retry after the branch moved reports B1 and B2, with B2 not published",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedBranchIsReportedNotPublished() async throws {
        let retry = try await movedBranchRetry()
        let (shortB1, shortB2) = (oq191Short(retry.commitB1), oq191Short(retry.commitB2))

        let reports = try #require(try await retry.world.unpublishedReports("mobile"))
        #expect(reports.contains { $0.contains(shortB1) && $0.contains(shortB2) })
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 2: characterization: a retry after the branch moved lands the Cycle",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func movedBranchStillLands() async throws {
        let retry = try await movedBranchRetry()

        #expect(retry.second.error == nil)
        #expect(try retry.world.isCycleLanded)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: an unchanged retry does not call the push seam again",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unchangedRetryDoesNotPushAgain() async throws {
        let world = try await unchangedRetry().world

        #expect(world.pushCalls("backend") == 1)
        #expect(world.pushCalls("mobile") == 1)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: characterization: an unchanged retry runs no second Verification",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unchangedRetryIsNotJudgedAgain() async throws {
        let retry = try await unchangedRetry()
        let (world, first, second) = (retry.world, retry.first, retry.second)

        #expect(first.dispatch.requests.count == 1)
        #expect(second.dispatch.requests.isEmpty)
        #expect(try world.env.journal.events(ofType: .featureVerified).count == 1)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: characterization: an unchanged retry opens no second pull request and lands",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unchangedRetryOpensNoSecondPullRequest() async throws {
        let retry = try await unchangedRetry()
        let (world, second) = (retry.world, retry.second)

        #expect(await world.publication.opened("backend").count == 1)
        #expect(await world.publication.opened("mobile").count == 1)
        #expect(await world.publication.calls.filter { $0.repository == "backend" }.count == 1)
        #expect(second.error == nil)
        #expect(try world.isCycleLanded)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: characterization: an unchanged retry writes the report under the same Outbox key",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unchangedRetryKeepsTheReportOutboxKey() async throws {
        let world = try await unchangedRetry().world

        let reports = try world.env.journal.outboxEntries(forIssue: "FEAT-1")
            .filter { $0.payload.contains(VerificationReport.managedBlockPrefix) }
        #expect(!reports.isEmpty)
        #expect(Set(reports.map(\.clientID)).count == 1)
    }

    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test(
        "item 1: characterization: a push the remote refused is pushed again on the next firing",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func refusedPushIsRetried() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        try backend.remote.installHook(named: "pre-receive", script: "#!/bin/sh\necho refused >&2\nexit 1\n")
        _ = await world.fire()
        try #require(await backend.remoteTip() == nil)
        try #require(try !world.isCycleLanded)
        try FileManager.default.removeItem(atPath: "\(backend.remote.path)/hooks/pre-receive")

        let second = await world.fire()

        #expect(world.pushCalls("backend") == 2)
        #expect(await backend.remoteTip() == backend.tip)
        #expect(second.error == nil)
        #expect(try world.isCycleLanded)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#one-recorded-verification
    @Test(
        "item 1, consequence: characterization: a faulted then a judged Verification record one Verification",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func faultThenVerdictRecordsOneVerification() async throws {
        let world = try await OQ191LandWorld.make()
        let faulted = await world.fire(verifier: .refuse)
        try #require(faulted.error != nil)
        try #require(try world.env.journal.featureVerification(cycleID: world.cycleID) == nil)

        _ = await world.fire()
        _ = await world.fire()

        #expect(try world.env.journal.featureVerification(cycleID: world.cycleID) != nil)
        #expect(try world.env.journal.events(ofType: .featureVerified).count == 1)
    }
}
