import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// The land Act's Worktree deallocation on push outcomes, split out of LandActPushTests.swift to keep that file
// under the file length limit.

extension LandActPushTests {
    @Test("A held Worktree is deallocated and released when a push is skipped due to zero commits ahead of Mainline")
    func heldWorktreeDeallocatedOnZeroCommitsSkippedPush() async throws {
        let local = TestGitRepo(name: "push-zero-dealloc-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])

        let remote = TestGitRepo(name: "push-zero-dealloc-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let workspace = ReconcilerFakeWorkspace()
        let env = try await Environment.make(repos: [repo], workspace: workspace)
        let (feature, cycleID) = try env.setUpFeature()
        try env.recordHeldWorktree(featureID: feature.id, repository: "backend", worktreeID: "wt-backend")

        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let pushStep = try #require(env.pushStep(repository: "backend"))
        #expect(pushStep.outcome == .skipped)

        let releaseStep = try #require(env.releaseWorktreeStep(repository: "backend"))
        #expect(releaseStep.outcome == .completed)

        #expect(
            workspace.removeCalls == [
                ReconcilerFakeWorkspace.RemoveCall(id: WorktreeID(rawValue: "wt-backend"), force: true)
            ]
        )
        #expect(try env.journal.heldWorktree(featureID: feature.id, repository: "backend") == nil)
    }

    @Test("A held Worktree is deallocated and released when a push is skipped because the Feature Branch is absent")
    func heldWorktreeDeallocatedOnAbsentBranchSkippedPush() async throws {
        let local = TestGitRepo(name: "push-absent-dealloc-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")

        let remote = TestGitRepo(name: "push-absent-dealloc-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let workspace = ReconcilerFakeWorkspace()
        let env = try await Environment.make(repos: [repo], workspace: workspace)
        let (feature, cycleID) = try env.setUpFeature()
        try env.recordHeldWorktree(featureID: feature.id, repository: "backend", worktreeID: "wt-backend")

        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let pushStep = try #require(env.pushStep(repository: "backend"))
        #expect(pushStep.outcome == .skipped)

        let releaseStep = try #require(env.releaseWorktreeStep(repository: "backend"))
        #expect(releaseStep.outcome == .completed)

        #expect(
            workspace.removeCalls == [
                ReconcilerFakeWorkspace.RemoveCall(id: WorktreeID(rawValue: "wt-backend"), force: true)
            ]
        )
        #expect(try env.journal.heldWorktree(featureID: feature.id, repository: "backend") == nil)
    }

    @Test("A held Worktree is not released or deallocated when a push fails")
    func heldWorktreeNotReleasedOnFailedPush() async throws {
        let local = TestGitRepo(name: "push-failed-hold-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-failed-hold-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        try remote.installHook(
            named: "pre-receive",
            script: """
            #!/bin/sh
            echo "GH006: Protected branch update failed" 1>&2
            exit 1
            """
        )
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let workspace = ReconcilerFakeWorkspace()
        let env = try await Environment.make(repos: [repo], workspace: workspace)
        let (feature, cycleID) = try env.setUpFeature()
        try env.recordHeldWorktree(featureID: feature.id, repository: "backend", worktreeID: "wt-backend")

        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let pushStep = try #require(env.pushStep(repository: "backend"))
        #expect(pushStep.outcome == .failed)

        let releaseStep = try #require(env.releaseWorktreeStep(repository: "backend"))
        #expect(releaseStep.outcome == .skipped)
        #expect(releaseStep.detail == "not pushed")

        #expect(workspace.removeCalls.isEmpty)
        let held = try #require(try env.journal.heldWorktree(featureID: feature.id, repository: "backend"))
        #expect(held.isHeld)
    }
}
