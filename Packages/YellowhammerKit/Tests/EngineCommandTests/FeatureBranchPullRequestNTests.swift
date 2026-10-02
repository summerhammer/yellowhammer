import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// risks OQ107: the pull request body's repository count is N — the repositories that pushed a Feature
// Branch — not the touched repositories. Rendered string only; nothing about GitHub.

@Suite("Land Act pull request body: the repository count is N (OQ107)")
struct FeatureBranchPullRequestNTests {
    @Test("A touched repository with the No-Pushed-Branch Outcome is not counted in the body's N")
    func bodyCountsPushedRepositoriesOnly() async throws {
        let local = TestGitRepo(name: "pr-n-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let cycleID = try FeatureBranchPullRequestTests.setUpPartialLandingFixture(env.journal)
        let (feature, _) = try #require(try env.journal.inFlightFeature())
        try recordTouchedRepositories(env.journal, featureID: feature.id, repositories: ["backend", "mobile"])
        try env.journal.append(
            .noPushedBranchOutcome(cycleID: cycleID, featureIssueID: "FEAT-1", repository: "mobile"),
            act: .land, runID: env.context.runID, nightID: env.context.night.id
        )

        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        _ = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )

        let body = try #require(await stub.calls.first?.body)
        #expect(body.contains("0 of 1 merged"))
        #expect(body.contains("This pull request is 1 of 1 for Feature"))
        #expect(body.contains("Merging all 1 pull requests"))
        #expect(!body.contains("of 2"))
    }
}
