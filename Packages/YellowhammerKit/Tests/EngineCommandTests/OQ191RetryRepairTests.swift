import Domain
@testable import Engine
import Foundation
import GRDB
@testable import Journal
import Repositories
import Testing

// OQ191 (yellowhammer#708), the land Act's retry repairs: a step that finds its work already recorded on a later
// firing still repairs the neighbouring write a failed firing left undone, and a retry never repeats a report it
// already made. Each case simulates the failure between two firings, on the real-git world.

/// Given: backend pushed and recorded, its pull request refused, so the Worktree stays held and the Cycle unlanded.
private func heldAfterRefusedPullRequest() async throws -> OQ191LandWorld {
    let world = try await OQ191LandWorld.make(withMobile: false, refusingPullRequest: ["backend"])
    let first = await world.fire()
    try #require(first.error == nil)
    try #require(try !world.isCycleLanded)
    try #require(try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend") != nil)
    return world
}

@Suite("OQ191 retry repairs: an already-recorded step repairs its neighbour", .serialized, .tags(.oq191))
struct OQ191RetryRepairTests {
    // landing/stories/open-one-pull-request-per-repository.md#publication-retry
    @Test("a retry records the Pushed Tip on the held Worktree when the first firing did not, and lands")
    func retryRecordsTheWorktreePush() async throws {
        let world = try await heldAfterRefusedPullRequest()
        try world.env.journal.write { db in try db.execute(sql: "UPDATE worktree SET pushed_commit = NULL") }
        let held = try #require(try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend"))
        try #require(held.pushedCommit == nil)

        let second = await world.fire()

        #expect(second.error == nil)
        #expect(world.pushCalls("backend") == 1)
        #expect(try world.isCycleLanded)
        #expect(try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend") == nil)
    }

    // feature-authoring/stories/select-the-next-feature.md#pushed-tip
    @Test("a retry writes the landed pin again when the first firing's pin is missing")
    func retryRestoresAMissingLandedPin() async throws {
        let world = try await heldAfterRefusedPullRequest()
        let backend = world["backend"]
        let pinRef = LandedTipPin.ref(for: landBranch)
        try #require(await oq191RevParse(backend.clone.path, pinRef) == backend.tip)
        try #require(await oq191Git(backend.clone.path, ["update-ref", "-d", pinRef]).isSuccess)

        let second = await world.fire()

        #expect(second.error == nil)
        #expect(await oq191RevParse(backend.clone.path, pinRef) == backend.tip)
        #expect(try world.env.journal.events(ofType: .landedPinFailed).isEmpty)
    }

    // feature-authoring/stories/select-the-next-feature.md#pushed-tip
    @Test("a retry moves a landed pin that points elsewhere back to the Pushed Tip")
    func retryRepointsAStrayLandedPin() async throws {
        let world = try await heldAfterRefusedPullRequest()
        let backend = world["backend"]
        let pinRef = LandedTipPin.ref(for: landBranch)
        try #require(await oq191Git(backend.clone.path, ["update-ref", pinRef, backend.base]).isSuccess)

        _ = await world.fire()

        #expect(await oq191RevParse(backend.clone.path, pinRef) == backend.tip)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("a Worktree directory that is no longer a git work tree is released, saying nothing was pinned")
    func notAWorkTreeIsReleased() async throws {
        let world = try await heldAfterRefusedPullRequest()
        let backend = world["backend"]
        try FileManager.default.removeItem(atPath: "\(backend.worktree)/.git")

        let second = await world.fire()

        #expect(second.error == nil)
        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .completed)
        #expect(step.detail?.contains("nothing was pinned") == true)
        #expect(try world.isCycleLanded)
        #expect(try world.env.journal.events(ofType: .unpublishedCommitsPinned).isEmpty)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("a release that faults after the pin does not pin or report the same HEAD again on the retry")
    func pinIsNotRepeatedWhenReleaseFaults() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", backend.tip])
        let head = try await backend.commitInWorktree("backend-unpublished.txt")
        try world.env.journal.write { db in
            try db.execute(sql: """
            CREATE TRIGGER oq191_fail_release BEFORE UPDATE OF released_at ON worktree
            BEGIN SELECT RAISE(ABORT, 'oq191 release fault'); END
            """)
        }

        let first = await world.fire()
        try #require(first.error != nil)
        try #require(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .failed)
        try #require(try world.env.journal.events(ofType: .unpublishedCommitsPinned).count == 1)
        try world.env.journal.write { db in try db.execute(sql: "DROP TRIGGER oq191_fail_release") }

        let second = await world.fire()

        #expect(second.error == nil)
        #expect(try world.env.journal.events(ofType: .unpublishedCommitsPinned).count == 1)
        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        #expect(try world.isCycleLanded)
        #expect(await oq191RevParse(backend.clone.path, "refs/yellowhammer/unpublished/\(landBranch.name)") == head)
    }
}
