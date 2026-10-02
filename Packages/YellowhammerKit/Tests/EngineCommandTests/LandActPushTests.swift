import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.2: the land Act's Repo Lane push, through the real ``FeatureBranchLanePush`` seam.
// Exercises ``LandAct/run(lane:feature:cycleID:context:)`` directly (rather than the full
// `EngineInvocation`, which would also require a real Board Port for the Night Card) against real
// fixture git repositories with local bare remotes, mirroring `FeatureBranchPusherTests`.

@Suite("Land Act push (P10.2)")
struct LandActPushTests {
    @Test("A pushed Feature Branch lands the tip on the remote, records the push, and comments on each done Card")
    func pushedRecordsAndComments() async throws {
        let local = TestGitRepo(name: "push-ok-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        let featureSHA = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-ok-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .completed)
        #expect(step.detail == featureSHA)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == featureSHA)

        let comments = await env.board.comments
        #expect(comments.contains { $0.issue.rawValue == "BACK-1" && $0.body.contains(featureSHA) })
    }

    @Test("A Feature Branch that does not exist in the repository is no completed work; nothing is pushed")
    func noCompletedWorkBranchAbsent() async throws {
        let local = TestGitRepo(name: "push-absent-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")

        let remote = TestGitRepo(name: "push-absent-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        try recordTouchedRepositories(env.journal, featureID: feature.id, repositories: ["backend"])

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .skipped)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)
        let comments = await env.board.comments
        #expect(comments.isEmpty)
        // P19.6 (OQ104, OQ107): the real pusher's verdict is recorded as the No-Pushed-Branch Outcome.
        #expect(try env.journal.noPushedBranchRepositories(featureID: feature.id) == ["backend"])
    }

    @Test("A Feature Branch with no commits ahead of Mainline is no completed work; nothing is pushed")
    func noCompletedWorkZeroCommitsAhead() async throws {
        let local = TestGitRepo(name: "push-zero-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])

        let remote = TestGitRepo(name: "push-zero-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        let (feature, cycleID) = try env.setUpFeature()
        try recordTouchedRepositories(env.journal, featureID: feature.id, repositories: ["backend"])

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .skipped)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)
        // P19.6 (OQ104, OQ107): the real pusher's verdict is recorded as the No-Pushed-Branch Outcome.
        #expect(try env.journal.noPushedBranchRepositories(featureID: feature.id) == ["backend"])
    }

    @Test("Branch protection on the remote records a failed step and comments on the Feature Issue")
    func branchProtectionRefusal() async throws {
        let local = TestGitRepo(name: "push-protected-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-protected-remote")
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
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)

        let comments = await env.board.comments
        #expect(comments.contains {
            $0.issue.rawValue == "FEAT-1" && $0.body.contains("backend") && $0.body.contains("yh-proj-feat")
                && $0.body.contains("branch protection")
        })
    }

    @Test("A token closure that throws is reported as missing credentials; the remote is never touched")
    func credentialsMissing() async throws {
        let local = TestGitRepo(name: "push-creds-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-creds-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        struct TokenError: Error {}
        let land = LandAct(push: FeatureBranchLanePush(token: { throw TokenError() }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)

        let comments = await env.board.comments
        #expect(comments.contains { $0.issue.rawValue == "FEAT-1" && $0.body.contains("credentials") })
    }

    @Test("A Feature Branch equal to the default branch refuses as Mainline; the remote main is unchanged")
    func mainlineRefused() async throws {
        let local = TestGitRepo(name: "push-mainline-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")

        let remote = TestGitRepo(name: "push-mainline-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature(branch: FeatureBranch(rawValue: "main"))

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/main") == nil)
    }

    @Test("One lane's push failure does not stop another lane from running")
    func otherLaneStillRuns() async throws {
        let backendLocal = TestGitRepo(name: "push-multi-backend-local")
        await backendLocal.initRepo(defaultBranch: "main")
        _ = try await backendLocal.commit(message: "initial")
        _ = await backendLocal.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await backendLocal.commit(filename: "feat.txt", content: "feature", message: "feature work")
        let backendRemote = TestGitRepo(name: "push-multi-backend-remote")
        await backendRemote.initRepo(bare: true, defaultBranch: "main")
        try backendRemote.installHook(
            named: "pre-receive",
            script: """
            #!/bin/sh
            echo "GH006: Protected branch update failed" 1>&2
            exit 1
            """
        )
        await backendLocal.addRemote(url: backendRemote.path)

        let mobileLocal = TestGitRepo(name: "push-multi-mobile-local")
        await mobileLocal.initRepo(defaultBranch: "main")
        _ = try await mobileLocal.commit(message: "initial")
        _ = await mobileLocal.run(["checkout", "-b", "yh-proj-feat"])
        let mobileSHA = try await mobileLocal.commit(
            filename: "feat.txt", content: "feature", message: "feature work"
        )
        let mobileRemote = TestGitRepo(name: "push-multi-mobile-remote")
        await mobileRemote.initRepo(bare: true, defaultBranch: "main")
        await mobileLocal.addRemote(url: mobileRemote.path)

        let backendRepo = Repo(name: "backend", path: backendLocal.path, role: .backend, defaultBranch: "main")
        let mobileRepo = Repo(name: "mobile", path: mobileLocal.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [backendRepo, mobileRepo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        await env.board.seed(issue: "MOB-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature(secondRepository: "mobile")

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let cards = try env.journal.cards(cycleID: cycleID)
        let backendFailure = await land.run(
            lane: RepoLane(repository: "backend", cards: cards.filter { $0.repository == "backend" }),
            feature: feature, cycleID: cycleID, context: env.context
        )
        let mobileFailure = await land.run(
            lane: RepoLane(repository: "mobile", cards: cards.filter { $0.repository == "mobile" }),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(backendFailure == nil)
        #expect(mobileFailure == nil)

        let backendStep = try #require(env.pushStep(repository: "backend"))
        #expect(backendStep.outcome == .failed)
        let mobileStep = try #require(env.pushStep(repository: "mobile"))
        #expect(mobileStep.outcome == .completed)
        #expect(mobileStep.detail == mobileSHA)
        await #expect(mobileRemote.revParse("refs/heads/yh-proj-feat") == mobileSHA)
    }
}
