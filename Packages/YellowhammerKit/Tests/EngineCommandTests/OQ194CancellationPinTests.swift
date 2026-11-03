import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// OQ194 (yellowhammer-spec 7ef1e7a), item 3: before cancellation releases a held Worktree whose HEAD is not the
// recorded commit, it pins that HEAD under refs/yellowhammer/unpublished/<branch>, as the land Act does at release
// (OQ191 item 6); the pinned commits are the Operator's (OQ193).

private struct TestWorktreeEnvironment {
    let clone: TestGitRepo
    let remote: TestGitRepo
    let worktreePath: String
    let base: String
}

private func makeGitWorktree(
    name: String = "backend", branch: String = settleFeatureBranch
) async throws -> TestWorktreeEnvironment {
    let clone = TestGitRepo(name: "oq194-\(name)-clone")
    await clone.initRepo(defaultBranch: "main")
    let base = try await clone.commit(filename: "README.md", content: name, message: "initial")
    let remote = TestGitRepo(name: "oq194-\(name)-remote")
    await remote.initRepo(bare: true, defaultBranch: "main")
    await clone.addRemote(url: remote.path)
    #expect(await clone.run(["push", "origin", "main"]).isSuccess)
    let worktreeURL = clone.url.appending(component: "wt-\(name)", directoryHint: .isDirectory)
    let worktreePath = worktreeURL.path(percentEncoded: false)
    #expect(await clone.run(["worktree", "add", "-b", branch, worktreePath]).isSuccess)
    return TestWorktreeEnvironment(clone: clone, remote: remote, worktreePath: worktreePath, base: base)
}

private func commitInWorktree(
    _ worktreePath: String, filename: String = "work.txt", content: String = "content", message: String = "commit"
) async throws -> String {
    let fileURL = URL(fileURLWithPath: worktreePath).appendingPathComponent(filename)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
    let git = GitRunner()
    _ = await git.run(["-C", worktreePath, "add", "."])
    _ = await git.run(["-C", worktreePath, "commit", "-m", message])
    let res = await git.run(["-C", worktreePath, "rev-parse", "--verify", "HEAD"])
    return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func moveBranchInClone(_ clonePath: String, branch: String, base: String) async throws -> String {
    let git = GitRunner()
    let filename = "extra-\(UUID().uuidString).txt"
    try "extra content".write(toFile: "\(clonePath)/\(filename)", atomically: true, encoding: .utf8)
    _ = await git.run(["-C", clonePath, "add", filename])
    let tree = (await git.run(["-C", clonePath, "write-tree"])).stdout
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let commit = (await git.run([
        "-C", clonePath, "commit-tree", tree, "-p", base, "-m", "moved branch commit"
    ])).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = await git.run(["-C", clonePath, "update-ref", "refs/heads/\(branch)", commit])
    _ = await git.run(["-C", clonePath, "reset", "--hard", "HEAD"])
    return commit
}

private func unpublishedPins(at commit: String, in path: String) async -> [String] {
    let listed = await GitRunner().run([
        "-C", path, "for-each-ref", "--points-at", commit, "--format=%(refname)"
    ]).stdout
    return listed.split(separator: "\n").map(String.init).filter {
        $0.hasPrefix("refs/yellowhammer/unpublished/")
    }
}

private func unexpectedPins(in path: String) async -> [String] {
    let listed = await GitRunner().run(["-C", path, "for-each-ref", "--format=%(refname)"]).stdout
    return listed.split(separator: "\n").map(String.init).filter {
        $0.hasPrefix("refs/yellowhammer/unpublished/")
    }
}

private func inFlightFeature(_ world: SettleWorld) throws -> FeatureRecord {
    try #require(try world.journal.inFlightFeature()?.feature)
}

/// Records `commit` as the Pushed Tip of the world's Cycle in `repository`, under an Act lease.
private func recordPushedTip(_ world: SettleWorld, repository: String, commit: String) throws {
    let runID = RunID()
    guard case .claimed = try world.journal.claimActLease(act: .land, runID: runID, mode: .real) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    try world.journal.recordPushedTip(
        cycleID: world.cycleID, repository: repository, commit: commit, runID: runID
    )
    try world.journal.releaseActLease(runID: runID)
}

@Suite("OQ194 cancellation pin: pin unpublished Worktree HEADs before cancellation releases them", .serialized)
struct OQ194CancellationPinTests {
    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("Case 1: HEAD after Pushed Tip is pinned, recorded, commented, worktree removed, abandonedAt set, survives")
    func descendantHeadIsPinned() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")
        let head = try await commitInWorktree(env.worktreePath, filename: "unpublished.txt", message: "unpublished")

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        let foundPins = await unpublishedPins(at: head, in: env.clone.path)
        #expect(foundPins == [pinRef])

        let events = try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation)
        #expect(events.count == 1)
        let event = try #require(events.first?.event)
        #expect(event.payload?["commits_after"] == "1")
        #expect(event.payload?["descends"] == "true")
        #expect(event.payload?["pin_ref"] == pinRef)

        let comments = await world.boards.writing.comments
        #expect(comments.contains { $0.issue.rawValue == "FEAT-1" && $0.body.contains(pinRef) })

        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)

        let row = try settleFeatureRow(world.journal, featureID: world.featureID)
        #expect(row.abandonedAt != nil)

        // The pin survives the abandon
        #expect(await !unpublishedPins(at: head, in: env.clone.path).isEmpty)

        // Nothing is pushed to remote
        let remoteRefs = await GitRunner().run(["-C", env.remote.path, "for-each-ref", "--points-at", head]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteRefs.isEmpty)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("Case 2: rewritten HEAD not descending from Pushed Tip is pinned, and report says differs")
    func rewrittenHeadIsPinnedAndReported() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")

        // Detach at base so HEAD does not descend from pushedTip
        _ = await GitRunner().run(["-C", env.worktreePath, "checkout", "--quiet", "--detach", env.base])
        let head = try await commitInWorktree(env.worktreePath, filename: "rewritten.txt", message: "rewritten")
        #expect(await GitRunner().run([
            "-C", env.worktreePath, "merge-base", "--is-ancestor", pushedTip, head
        ]).isSuccess == false)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        let foundPins = await unpublishedPins(at: head, in: env.clone.path)
        #expect(foundPins == [pinRef])

        let events = try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation)
        #expect(events.count == 1)
        let event = try #require(events.first?.event)
        #expect(event.payload?["commits_after"] == nil)
        #expect(event.payload?["descends"] == "false")
        #expect(event.payload?["pin_ref"] == pinRef)

        let comments = await world.boards.writing.comments
        #expect(comments.contains { $0.issue.rawValue == "FEAT-1" && $0.body.contains("differs") })
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("Case 3: HEAD at Pushed Tip makes no pin, no event, and Worktree is released")
    func headAtPushedTipMakesNoPin() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(await unexpectedPins(in: env.clone.path).isEmpty)
        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).isEmpty)
        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("Case 4: unpushed Worktree with commits after base is pinned against base with noPushedBranch true")
    func unpushedWorktreeIsPinnedAgainstBase() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let head = try await commitInWorktree(env.worktreePath, filename: "unpushed.txt", message: "unpushed")

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try world.journal.recordFeatureBases(featureID: world.featureID, bases: [
            FeatureBaseRecord(repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: env.base)
        ])
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: nil)

        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        let foundPins = await unpublishedPins(at: head, in: env.clone.path)
        #expect(foundPins == [pinRef])

        let events = try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation)
        #expect(events.count == 1)
        let event = try #require(events.first?.event)
        #expect(event.payload?["no_pushed_branch"] == "true")
        #expect(event.payload?["commits_after"] == "1")
        #expect(event.payload?["descends"] == "true")
        #expect(event.payload?["pin_ref"] == pinRef)
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("Case 5: pin cannot be written defers abandon with CycleArchiveFault until unblocked")
    func failedPinDefersAbandonUntilUnblocked() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")
        let head = try await commitInWorktree(env.worktreePath, filename: "unpublished.txt", message: "unpublished")

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        // Block git from creating directory/ref refs/yellowhammer/unpublished/<branch>
        let blockerURL = env.clone.url.appendingPathComponent(".git/refs/yellowhammer/unpublished")
        try FileManager.default.createDirectory(
            at: blockerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "blocker".write(to: blockerURL, atomically: true, encoding: .utf8)

        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        await #expect(throws: CycleArchiveFault.self) {
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
            )
        }

        #expect(world.workspace.removeCalls.isEmpty)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        #expect(await unpublishedPins(at: head, in: env.clone.path).isEmpty)

        // Remove the blocker and settle again
        try FileManager.default.removeItem(at: blockerURL)

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        #expect(await unpublishedPins(at: head, in: env.clone.path) == [pinRef])
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
    }

    // landing/stories/open-one-pull-request-per-repository.md#unpublished-commits-pin
    @Test("Case 6: second settle after success writes no second event and no second comment")
    func repeatSettleWritesNoSecondEventOrComment() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")
        _ = try await commitInWorktree(env.worktreePath, filename: "unpublished.txt", message: "unpublished")

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).count == 1)
        let commentCalls = await world.boards.writing.createCommentCalls

        let feature = try settleFeatureRecord(world.journal, featureID: world.featureID)
        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)

        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).count == 1)
        #expect(await world.boards.writing.createCommentCalls == commentCalls)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Case 7: Gone directory with branch in main clone moved -> pinned, reported, worktree removed, cancelled")
    func goneDirectoryWithMovedBranchIsPinnedAndReleased() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")

        let branchCommit = try await moveBranchInClone(
            env.clone.path, branch: settleFeatureBranch, base: pushedTip
        )
        try FileManager.default.removeItem(atPath: env.worktreePath)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let repos = ProjectRepositories(workingRepos: [Repo(name: "backend", path: env.clone.path, role: .backend)])
        let context = try world.makeContext(repositories: repos)

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        let foundPins = await unpublishedPins(at: branchCommit, in: env.clone.path)
        #expect(foundPins == [pinRef])

        let events = try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation)
        #expect(events.count == 1)
        let event = try #require(events.first?.event)
        #expect(event.payload?["pin_ref"] == pinRef)

        let comments = await world.boards.writing.comments
        #expect(comments.contains { $0.issue.rawValue == "FEAT-1" && $0.body.contains(pinRef) })

        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Case 8: Gone directory with branch in main clone at recorded commit or absent -> released with no pin")
    func goneDirectoryWithBranchAtRecordedCommitOrAbsentReleasesWithNoPin() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")
        try FileManager.default.removeItem(atPath: env.worktreePath)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let repos = ProjectRepositories(workingRepos: [Repo(name: "backend", path: env.clone.path, role: .backend)])
        let context = try world.makeContext(repositories: repos)

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(await unexpectedPins(in: env.clone.path).isEmpty)
        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).isEmpty)
        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Case 9: Non-git directory with moved branch: pinned and reported, throws CycleArchiveFault, stays held")
    func nonGitDirectoryWithMovedBranchThrowsAndStaysHeld() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")

        let branchCommit = try await moveBranchInClone(
            env.clone.path, branch: settleFeatureBranch, base: pushedTip
        )
        try FileManager.default.removeItem(atPath: env.worktreePath)
        try FileManager.default.createDirectory(atPath: env.worktreePath, withIntermediateDirectories: true)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let repos = ProjectRepositories(workingRepos: [Repo(name: "backend", path: env.clone.path, role: .backend)])
        let context = try world.makeContext(repositories: repos)

        await #expect(throws: CycleArchiveFault.self) {
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
            )
        }

        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        let foundPins = await unpublishedPins(at: branchCommit, in: env.clone.path)
        #expect(foundPins == [pinRef])

        let events = try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation)
        #expect(events.count == 1)

        let comments = await world.boards.writing.comments
        #expect(comments.contains { $0.issue.rawValue == "FEAT-1" && $0.body.contains(pinRef) })

        #expect(world.workspace.removeCalls.isEmpty)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)

        let held = try #require(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend"))
        #expect(held.isHeld)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Case 10: Non-git directory retry: no duplicate report, stays held; removing directory releases as gone")
    func nonGitDirectoryRetryStaysHeldThenReleasesWhenRemoved() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")

        _ = try await moveBranchInClone(
            env.clone.path, branch: settleFeatureBranch, base: pushedTip
        )
        try FileManager.default.removeItem(atPath: env.worktreePath)
        try FileManager.default.createDirectory(atPath: env.worktreePath, withIntermediateDirectories: true)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let repos = ProjectRepositories(workingRepos: [Repo(name: "backend", path: env.clone.path, role: .backend)])
        let context = try world.makeContext(repositories: repos)

        // First attempt: pins and throws CycleArchiveFault
        await #expect(throws: CycleArchiveFault.self) {
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
            )
        }
        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).count == 1)
        let pinRef = "refs/yellowhammer/unpublished/\(settleFeatureBranch)"
        let initialPinComments = (await world.boards.writing.comments).filter { $0.body.contains(pinRef) }
        #expect(!initialPinComments.isEmpty)
        let commentCalls = await world.boards.writing.createCommentCalls

        // Second attempt: already pinned, still non-git, throws CycleArchiveFault with no new event or comment
        let feature = try settleFeatureRecord(world.journal, featureID: world.featureID)
        await #expect(throws: CycleArchiveFault.self) {
            try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)
        }
        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).count == 1)
        #expect(await world.boards.writing.createCommentCalls == commentCalls)

        // Operator removes the directory
        try FileManager.default.removeItem(atPath: env.worktreePath)

        // Third attempt: treated as gone, alreadyPinned -> releases with no duplicate pin report or pin comment
        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)
        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).count == 1)
        let finalPinComments = (await world.boards.writing.comments).filter { $0.body.contains(pinRef) }
        #expect(finalPinComments == initialPinComments)
        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
    }

    // landing/open-one-pull-request-per-repository#pin-failure
    @Test("Case 11: Lead judgement: Main clone unreadable or pin write refused throws CycleArchiveFault")
    func unreadableMainCloneThrowsCycleArchiveFault() async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")

        _ = try await moveBranchInClone(
            env.clone.path, branch: settleFeatureBranch, base: pushedTip
        )
        try FileManager.default.removeItem(atPath: env.worktreePath)

        // Block git from creating directory/ref refs/yellowhammer/unpublished/<branch>
        let blockerURL = env.clone.url.appendingPathComponent(".git/refs/yellowhammer/unpublished")
        try FileManager.default.createDirectory(
            at: blockerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "blocker".write(to: blockerURL, atomically: true, encoding: .utf8)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let repos = ProjectRepositories(workingRepos: [Repo(name: "backend", path: env.clone.path, role: .backend)])
        let context = try world.makeContext(repositories: repos)

        await #expect(throws: CycleArchiveFault.self) {
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
            )
        }

        #expect(world.workspace.removeCalls.isEmpty)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        #expect(try world.journal.events(ofType: .unpublishedCommitsPinnedAtCancellation).isEmpty)
    }
}

extension OQ194CancellationPinTests {
    /// The main clone a cancellation reads cannot be read: a path that is no git repository, or no path at all.
    enum UnreadableMainClone: CaseIterable, Sendable {
        case notAGitRepository
        case noConfiguredPath
    }

    // landing/stories/open-one-pull-request-per-repository.md#pin-failure
    @Test(
        "Case 12: Lead judgement: a gone directory whose main clone cannot be read throws CycleArchiveFault, held",
        arguments: UnreadableMainClone.allCases
    )
    func unreadableMainCloneKeepsGoneWorktreeHeld(_ unreadable: UnreadableMainClone) async throws {
        let world = try await makeSettleWorld()
        let env = try await makeGitWorktree()
        let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")
        try FileManager.default.removeItem(atPath: env.worktreePath)

        try world.journal.recordFeatureBranch(
            featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
        )
        try recordPushedTip(world, repository: "backend", commit: pushedTip)
        try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)

        await world.seedFeatureCancelled()
        let repos: ProjectRepositories
        switch unreadable {
        case .notAGitRepository:
            let plain = FileManager.default.temporaryDirectory
                .appending(component: "oq194-not-a-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
            repos = ProjectRepositories(
                workingRepos: [Repo(name: "backend", path: plain.path(percentEncoded: false), role: .backend)]
            )
        case .noConfiguredPath:
            repos = ProjectRepositories(workingRepos: [])
        }
        let context = try world.makeContext(repositories: repos)

        await #expect(throws: CycleArchiveFault.self) {
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
            )
        }

        #expect(world.workspace.removeCalls.isEmpty)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .featureReleased).isEmpty)
        #expect(await unexpectedPins(in: env.clone.path).isEmpty)
    }
}
