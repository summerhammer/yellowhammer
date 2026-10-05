import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// The land Act pushes the Feature Branch recorded for the Repo Lane, which Orca ADE may have reported
// with a `<prefix>/` before the Worktree name. Split out to keep LandActPushTests.swift short.

extension LandActPushTests {
    @Test("A recorded prefixed Feature Branch is the ref pushed: the remote gets the prefixed name only")
    func pushesRecordedPrefixedFeatureBranch() async throws {
        let local = TestGitRepo(name: "push-prefix-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "rozd/yh-proj-feat"])
        let featureSHA = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "push-prefix-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        try env.journal.recordFeatureBranch(
            featureID: feature.id, repository: "backend", branch: FeatureBranch(name: "rozd/yh-proj-feat")
        )

        let land = LandAct(push: FeatureBranchLanePush(token: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )
        #expect(failure == nil)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .completed)
        await #expect(remote.revParse("refs/heads/rozd/yh-proj-feat") == featureSHA)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)
    }
}
