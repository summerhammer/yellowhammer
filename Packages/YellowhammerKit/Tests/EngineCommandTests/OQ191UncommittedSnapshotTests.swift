import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ196 item 1 (landing/open-one-pull-request-per-repository#uncommitted-snapshot): before the land Act releases a
// held Worktree it saves the Worktree's uncommitted changes as a snapshot under a local ref outside refs/heads/.
// A snapshot that cannot be written keeps the Worktree held and the next land firing tries again. Real git per
// repository; the assertions are on refs, the Journal, board comments and the release step, never on a push or a
// pull request body.

private var snapshotRef: String { "refs/yellowhammer/snapshot/\(landBranch.name)" }

/// Backend's held Worktree at its Feature Branch tip (the Pushed Tip to be) with a modified tracked file and an
/// untracked file.
private func dirtyBackend(_ world: OQ191LandWorld) throws {
    let worktree = world["backend"].worktree
    try "changed".write(toFile: "\(worktree)/backend-work.txt", atomically: true, encoding: .utf8)
    try "fresh".write(toFile: "\(worktree)/scratch.txt", atomically: true, encoding: .utf8)
}

private func snapshotComments(_ world: OQ191LandWorld, on issue: String) async -> [String] {
    await world.env.board.comments.filter { $0.issue.rawValue == issue }.map(\.body)
        .filter { $0.hasPrefix("Not published:") && $0.contains("saved as a snapshot at") }
}

private func snapshotFailureComments(_ world: OQ191LandWorld, on issue: String) async -> [String] {
    await world.env.board.comments.filter { $0.issue.rawValue == issue }.map(\.body)
        .filter { $0.contains("could not be saved as a snapshot") }
}

@Suite("OQ196 uncommitted snapshot: saved before the land Act releases a Worktree", .serialized, .tags(.oq191))
struct OQ191UncommittedSnapshotTests {
    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a dirty Worktree at the recorded commit is snapshotted, reported and released")
    func dirtyWorktreeIsSnapshottedAndReleased() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        try dirtyBackend(world)

        let firing = await world.fire()
        try #require(firing.error == nil)

        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        let commit = try #require(await oq191RevParse(backend.clone.path, snapshotRef))
        let tree = await oq191Git(backend.clone.path, ["ls-tree", "-r", "--name-only", commit]).stdout
        #expect(tree.contains("scratch.txt"))
        #expect(await oq191RevParse(backend.clone.path, "refs/heads/\(landBranch.name)") == backend.tip)

        let events = try world.env.journal.events(ofType: .uncommittedChangesSnapshotted).map(\.event)
        #expect(events == [.uncommittedChangesSnapshotted(
            cycleID: world.cycleID,
            snapshot: UncommittedChangesSnapshot(
                repository: "backend", ref: snapshotRef, commit: commit, modified: 1, untracked: 1,
                atCancellation: false
            )
        )])
        let expected = try #require(events.first.flatMap(UnpublishedCommitsReport.text(of:)))
        #expect(expected.hasPrefix("Not published: 1 modified and 1 untracked files in `backend` were saved"))
        for issue in ["FEAT-1", "BACK-1"] {
            #expect(await snapshotComments(world, on: issue) == [expected])
        }
        let notes = try NightSummary.pullRequestLines(night: world.env.context.night, journal: world.env.journal)
        #expect(notes.contains(expected))
        #expect(try world.isCycleLanded)
        #expect(await oq191Git(backend.remoteDirectory, ["for-each-ref", "--points-at", commit]).stdout.isEmpty)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a dirty Worktree whose HEAD moved gets both the pin report and the snapshot report")
    func movedHeadAndDirtyReportsBoth() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        _ = await oq191Git(backend.worktree, ["checkout", "--quiet", "--detach", backend.tip])
        try await backend.commitInWorktree("backend-unpublished.txt")
        try dirtyBackend(world)

        let firing = await world.fire()
        try #require(firing.error == nil)

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .completed)
        #expect(step.detail?.contains("snapshot at \(snapshotRef)") == true)
        #expect(step.detail?.contains("pinned ") == true)
        #expect(await oq191RevParse(backend.clone.path, snapshotRef) != nil)
        let pinReports = await world.env.board.comments.map(\.body).filter { $0.contains("pinned at") }
        #expect(!pinReports.isEmpty)
        #expect(await snapshotComments(world, on: "FEAT-1").count == 1)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a clean Worktree makes no snapshot ref, event or comment")
    func cleanWorktreeMakesNoSnapshot() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)

        let firing = await world.fire()
        try #require(firing.error == nil)

        #expect(await oq191RevParse(world["backend"].clone.path, snapshotRef) == nil)
        #expect(try world.env.journal.events(ofType: .uncommittedChangesSnapshotted).isEmpty)
        #expect(await snapshotComments(world, on: "FEAT-1").isEmpty)
        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("a snapshot that cannot be written keeps the Worktree held, and the next firing saves it")
    func snapshotFailureKeepsHeldThenRetries() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        try dirtyBackend(world)
        let blocked = await oq191Git(backend.clone.path, ["update-ref", "\(snapshotRef)/blocker", backend.tip])
        try #require(blocked.isSuccess)

        let firing = await world.fire()
        try #require(firing.error == nil)

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        let detail = try #require(step.detail)
        #expect(detail.hasPrefix("Not landed: the uncommitted changes in the Worktree for `backend` could not be"))
        for issue in ["FEAT-1", "BACK-1"] {
            #expect(await snapshotFailureComments(world, on: issue) == [detail])
        }
        #expect(try !world.isCycleLanded)
        #expect(try world.env.journal.events(ofType: .uncommittedChangesSnapshotted).isEmpty)
        #expect(FileManager.default.fileExists(atPath: backend.worktree))

        _ = await oq191Git(backend.clone.path, ["update-ref", "-d", "\(snapshotRef)/blocker"])
        let retry = await world.fire()
        try #require(retry.error == nil)

        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        #expect(await oq191RevParse(backend.clone.path, snapshotRef) != nil)
        #expect(try world.isCycleLanded)
        #expect(await snapshotComments(world, on: "FEAT-1").count == 1)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("with no Feature Branch recorded, a dirty Worktree is kept held with no snapshot, and a clean one is not")
    func noFeatureBranchKeepsDirtyWorktreeHeld() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]

        let clean = await WorktreeSnapshotDecision.evaluate(
            worktreePath: backend.worktree, repository: "backend", branch: nil, moment: .land
        )
        guard case .nothingToSave = clean else {
            Issue.record("Expected .nothingToSave, got \(clean)")
            return
        }

        try dirtyBackend(world)
        let dirty = await WorktreeSnapshotDecision.evaluate(
            worktreePath: backend.worktree, repository: "backend", branch: nil, moment: .land
        )
        guard case .keepHeld(let comment) = dirty else {
            Issue.record("Expected .keepHeld, got \(dirty)")
            return
        }
        #expect(comment.body == LandFailureComment.snapshotWithoutBranch(repository: "backend", moment: .land).body)
        #expect(await oq191RevParse(backend.clone.path, snapshotRef) == nil)
    }
}
