import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// Pin Failure Ruling, item 2, as amended by OQ196 item 2:
// When a Worktree's directory is gone or is not a git work tree, the engine reads the Feature Branch in the
// main clone before release. If the branch resolves and is not the recorded commit, the engine pins it under
// refs/yellowhammer/unpublished/<branch> before release. A gone directory is released after the pin; a non-git
// directory stays held. Spec at landing/open-one-pull-request-per-repository.

private func pins(at commit: String, in path: String) async -> [String] {
    let listed = await oq191Git(path, ["for-each-ref", "--points-at", commit, "--format=%(refname)"]).stdout
    return listed.split(separator: "\n").map(String.init).filter {
        $0.hasPrefix("refs/yellowhammer/unpublished/")
    }
}

private func unexpectedPins(in path: String) async -> [String] {
    let listed = await oq191Git(path, ["for-each-ref", "--format=%(refname)"]).stdout
    return listed.split(separator: "\n").map(String.init).filter {
        $0.hasPrefix("refs/yellowhammer/unpublished/")
    }
}

private func moveBranchInClone(_ clonePath: String, branch: String, base: String) async throws -> String {
    let tempBranch = "temp-\(UUID().uuidString)"
    _ = await oq191Git(clonePath, ["checkout", "-b", tempBranch, base])
    let filename = "extra-\(UUID().uuidString).txt"
    try "extra content".write(toFile: "\(clonePath)/\(filename)", atomically: true, encoding: .utf8)
    _ = await oq191Git(clonePath, ["add", filename])
    _ = await oq191Git(clonePath, ["commit", "-m", "extra commit"])
    let commit = (await oq191Git(clonePath, ["rev-parse", "HEAD"])).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    _ = await oq191Git(clonePath, ["checkout", "main"])
    _ = await oq191Git(clonePath, ["branch", "-D", tempBranch])
    _ = await oq191Git(clonePath, ["update-ref", "refs/heads/\(branch)", commit])
    return commit
}

private func recordPushedTip(_ world: OQ191LandWorld, repository: String, commit: String) throws {
    try world.env.journal.recordPushedTip(
        cycleID: world.cycleID, repository: repository, commit: commit, runID: world.env.runID
    )
}

private func setupPushedTipAndMoveBranch(
    world: OQ191LandWorld, repository: String = "backend"
) async throws -> (backend: OQ191Repository, branchCommit: String) {
    let backend = world[repository]
    // Push the current feature branch tip to remote and record it in the Journal
    _ = await oq191Git(
        backend.clone.path, ["push", "origin", "refs/heads/\(landBranch.name):refs/heads/\(landBranch.name)"]
    )
    try recordPushedTip(world, repository: repository, commit: backend.tip)

    // Remove worktree directory
    try FileManager.default.removeItem(atPath: backend.worktree)

    // Move branch in clone past the pushed tip
    let branchCommit = try await moveBranchInClone(backend.clone.path, branch: landBranch.name, base: backend.tip)
    return (backend, branchCommit)
}

@Suite("OQ191 main clone pin: gone or non-git Worktrees", .serialized, .tags(.oq191))
struct OQ191MainClonePinTests {
    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Gone directory: branch in main clone resolves to a commit past the pushed tip -> pinned and released")
    func goneDirectoryMovedBranchPinnedAndReleased() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let (backend, branchCommit) = try await setupPushedTipAndMoveBranch(world: world)

        let firing = await world.fire()
        try #require(firing.error == nil)

        let pinRef = "refs/yellowhammer/unpublished/\(landBranch.name)"
        let foundPins = await pins(at: branchCommit, in: backend.clone.path)
        #expect(foundPins == [pinRef])

        let reports = try #require(try await world.unpublishedReports("backend"))
        #expect(reports.contains { $0.contains(pinRef) && $0.contains(oq191Short(branchCommit)) })

        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)

        // Pinned commit is not on the remote
        let remoteRefs = await oq191Git(backend.remote.path, ["for-each-ref", "--points-at", branchCommit]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteRefs.isEmpty)
        #expect(await backend.remoteTip() == backend.tip)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Gone directory: branch in main clone is at the recorded commit -> released with nothing pinned")
    func goneDirectoryBranchAtRecordedCommitReleased() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]

        try FileManager.default.removeItem(atPath: backend.worktree)

        let firing = await world.fire()
        try #require(firing.error == nil)

        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        #expect(await unexpectedPins(in: backend.clone.path).isEmpty)
        #expect(try await world.unpublishedReports("backend") == nil)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Gone directory: branch in main clone is absent -> released with nothing pinned")
    func goneDirectoryBranchAbsentReleased() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]

        try FileManager.default.removeItem(atPath: backend.worktree)
        _ = await oq191Git(backend.clone.path, ["branch", "-D", landBranch.name])

        let firing = await world.fire()
        try #require(firing.error == nil)

        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .completed)
        #expect(await unexpectedPins(in: backend.clone.path).isEmpty)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Non-git directory with moved branch: pin written and reported, release fails, Worktree held")
    func nonGitDirectoryMovedBranchPinnedAndHeld() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let (backend, branchCommit) = try await setupPushedTipAndMoveBranch(world: world)

        // Make it a non-git directory
        try FileManager.default.createDirectory(atPath: backend.worktree, withIntermediateDirectories: true)

        let firing = await world.fire()
        try #require(firing.error == nil)

        let pinRef = "refs/yellowhammer/unpublished/\(landBranch.name)"
        let foundPins = await pins(at: branchCommit, in: backend.clone.path)
        #expect(foundPins == [pinRef])

        let reports = try #require(try await world.unpublishedReports("backend"))
        #expect(reports.contains { $0.contains(pinRef) })

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        #expect(step.detail?.contains("not a git work tree") == true)

        let held = try #require(try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend"))
        #expect(held.isHeld)
        #expect(try !world.isCycleLanded)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Non-git directory retry: no duplicate report, stays held; removing directory releases as gone")
    func nonGitDirectoryRetryAndRecovery() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let (backend, branchCommit) = try await setupPushedTipAndMoveBranch(world: world)

        // Make it a non-git directory
        try FileManager.default.createDirectory(atPath: backend.worktree, withIntermediateDirectories: true)

        // First firing
        _ = await world.fire()
        let pinRef = "refs/yellowhammer/unpublished/\(landBranch.name)"
        #expect(await pins(at: branchCommit, in: backend.clone.path) == [pinRef])

        let eventsFirst = try world.env.journal.events(ofType: .unpublishedCommitsPinned)
        #expect(eventsFirst.count == 1)

        // Second firing (retry): directory still non-git
        _ = await world.fire()
        let stepSecond = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(stepSecond.outcome == .failed)

        let eventsSecond = try world.env.journal.events(ofType: .unpublishedCommitsPinned)
        #expect(eventsSecond.count == 1) // No second Journal event

        let reportsSecond = try #require(try await world.unpublishedReports("backend"))
        #expect(reportsSecond.count == 1) // No second comment

        // Operator removes the directory
        try FileManager.default.removeItem(atPath: backend.worktree)

        // Third firing: treated as gone, alreadyPinned -> releases!
        _ = await world.fire()
        let stepThird = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(stepThird.outcome == .completed)
        #expect(try world.isCycleLanded)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Lead judgement: Main clone unreadable or pin write refused keeps Worktree held")
    func unreadableMainCloneKeepsWorktreeHeld() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]

        // Push tip and record it so land's push sees it as already pushed
        _ = await oq191Git(
            backend.clone.path, ["push", "origin", "refs/heads/\(landBranch.name):refs/heads/\(landBranch.name)"]
        )
        try recordPushedTip(world, repository: "backend", commit: backend.tip)

        // Move branch in clone past pushed tip
        _ = try await moveBranchInClone(backend.clone.path, branch: landBranch.name, base: backend.tip)

        try FileManager.default.removeItem(atPath: backend.worktree)

        // Block git from creating directory/ref refs/yellowhammer/unpublished/<branch>
        let blockerURL = backend.clone.url.appendingPathComponent(".git/refs/yellowhammer/unpublished")
        try FileManager.default.createDirectory(
            at: blockerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "blocker".write(to: blockerURL, atomically: true, encoding: .utf8)

        _ = await world.fire()

        let step = try #require(world.env.releaseWorktreeStep(repository: "backend"))
        #expect(step.outcome == .failed)
        #expect(step.detail?.contains("could not be pinned before release") == true)

        let held = try #require(try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend"))
        #expect(held.isHeld)
        #expect(try !world.isCycleLanded)
    }
}
