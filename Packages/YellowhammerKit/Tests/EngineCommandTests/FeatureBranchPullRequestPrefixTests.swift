import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// The pull request head is the Feature Branch recorded for the Repo Lane, which Orca ADE may have
// reported with a `<prefix>/` before the Worktree name.

@Suite("Land Act pull request, Feature Branch prefix")
struct FeatureBranchPullRequestPrefixTests {
    @Test("A recorded prefixed Feature Branch is the pull request head and the {branch} of the title")
    func headIsRecordedPrefixedFeatureBranch() async throws {
        let local = TestGitRepo(name: "pr-prefix-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "rozd/yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        try env.journal.recordFeatureBranch(
            featureID: feature.id, repository: "backend", branch: FeatureBranch(name: "rozd/yh-proj-feat")
        )

        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(
            publication: stub, clock: { landEpoch },
            titleTemplate: try MessageTemplate("{branch}", kind: .pullRequestTitle), projectID: "proj"
        )
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)

        let calls = await stub.calls
        #expect(calls.count == 1)
        #expect(calls[0].head == "rozd/yh-proj-feat")
        #expect(calls[0].title == "rozd/yh-proj-feat")
    }
}
