import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 items 2, 5, 6 and 9 as built (landing/open-one-pull-request-per-repository#unpublished-commits-pin): the
// "not published" reports' wording (the spec's lead draft), where they are placed — the Feature Card, each Work
// Card of the lane, a Journal event and a Night Summary note that is not a failure — and the lead's decision that a
// pin that cannot be written keeps the Worktree held and the Cycle unlanded until a later firing pins it.

private func comments(_ world: OQ191LandWorld, on issue: String) async -> [String] {
    await world.env.board.comments.filter { $0.issue.rawValue == issue }.map(\.body)
}

private var pinRef: String { "refs/yellowhammer/unpublished/\(landBranch.name)" }

/// Backend's held Worktree on a detached HEAD two commits after its Feature Branch tip (the Pushed Tip to be).
private func backendTwoCommitsAhead(_ world: OQ191LandWorld) async throws -> String {
    let backend = world["backend"]
    _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", backend.tip])
    try await backend.commitInWorktree("backend-one.txt")
    return try await backend.commitInWorktree("backend-two.txt")
}

@Suite("Unpublished commits: the report's wording and placement, and a pin that cannot be written", .serialized)
struct UnpublishedCommitsReportTests {
    @Test("a pushed repository is reported at Verification time and at release, on the Feature Card and Work Card")
    func pushedRepositoryReports() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let head = try await backendTwoCommitsAhead(world)
        let (tip, shortHead) = (oq191Short(world["backend"].tip), oq191Short(head))

        let firing = await world.fire()
        try #require(firing.error == nil)

        let differs = "2 commits in backend after the Pushed Tip \(tip), up to \(shortHead)"
        let expected = [
            "Not published: \(differs). Verification judged \(tip).",
            "Not published: \(differs); pinned at `\(pinRef)`. The pull request is at \(tip)."
        ]
        #expect(await comments(world, on: "FEAT-1").filter { $0.hasPrefix("Not published:") } == expected)
        #expect(await comments(world, on: "BACK-1").filter { $0.hasPrefix("Not published:") } == expected)
        #expect(try world.isCycleLanded)
    }

    @Test("both reports are Journal events, and Night Summary notes that are not failures")
    func reportsAreEventsAndNotes() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let head = try await backendTwoCommitsAhead(world)
        let backend = world["backend"]

        _ = await world.fire()

        let journal = world.env.journal
        let unpublished = UnpublishedHead(
            repository: "backend", recordedCommit: backend.tip, head: head, commitsAfter: 2, noPushedBranch: false
        )
        let reported = try journal.events(ofType: .unpublishedCommitsReported).map(\.event)
        let pinned = try journal.events(ofType: .unpublishedCommitsPinned).map(\.event)
        #expect(reported == [.unpublishedCommitsReported(cycleID: world.cycleID, unpublished: unpublished)])
        #expect(pinned == [.unpublishedCommitsPinned(cycleID: world.cycleID, unpublished: unpublished, pinRef: pinRef)])

        let notes = try NightSummary.pullRequestLines(night: world.env.context.night, journal: journal)
        #expect(notes.filter { $0.hasPrefix("Not published:") }.count == 2)
        let failedSteps = try journal.events(ofType: .landStep).filter {
            if case .landStep(_, _, .failed, _) = $0.event { return true }
            return false
        }
        #expect(failedSteps.isEmpty)
    }

    @Test("a No-Pushed-Branch repository's release report names the recorded base commit and no pull request")
    func noPushedBranchReleaseReport() async throws {
        let world = try await OQ191LandWorld.make(noPushedBranch: ["mobile"])
        let mobile = world["mobile"]
        _ = await oq191Git(mobile.worktree, ["checkout", "--quiet", "--detach"])
        let head = try await mobile.commitInWorktree("mobile-past-base.txt")

        let firing = await world.fire()
        try #require(firing.error == nil)

        let differs = "1 commit in mobile after the recorded base commit \(oq191Short(mobile.base)), up to "
            + oq191Short(head)
        #expect(await comments(world, on: "FEAT-1").filter { $0.hasPrefix("Not published:") } == [
            "Not published: \(differs). Verification judged \(oq191Short(mobile.base)).",
            "Not published: \(differs); pinned at `\(pinRef)`. mobile has no pushed branch and no pull request."
        ])
        #expect(await oq191RevParse(mobile.clone.path, pinRef) == head)
        #expect(try world.isCycleLanded)
    }

    @Test("a pin that cannot be written fails the release step, keeps the Worktree held, and the next firing pins")
    func pinFailureKeepsTheWorktreeHeld() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let head = try await backendTwoCommitsAhead(world)
        let backend = world["backend"]
        // A file where the pin's directory must go: git cannot lock the ref.
        let blocker = URL(fileURLWithPath: backend.clone.path).appending(path: ".git/refs/yellowhammer/unpublished")
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "blocked".write(to: blocker, atomically: true, encoding: .utf8)

        _ = await world.fire()

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        #expect(step.detail?.contains("could not be pinned") == true)
        let held = try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend")
        #expect(held?.isHeld == true)
        let landedAfterFailure = try world.isCycleLanded
        #expect(!landedAfterFailure)
        #expect(try world.env.journal.events(ofType: .unpublishedCommitsPinned).isEmpty)

        try FileManager.default.removeItem(at: blocker)
        let retry = await world.fire()

        #expect(retry.error == nil)
        #expect(await oq191RevParse(backend.clone.path, pinRef) == head)
        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        #expect(try world.isCycleLanded)
        #expect(await comments(world, on: "FEAT-1").filter { $0.contains("pinned at") }.count == 1)
    }
}
