import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.5: the pull request seam reads the Cycle's recorded Verification itself, so the body it
// writes once carries the clause report — and is unchanged when Verification recorded nothing.

@Suite("Land Act pull request carries the Verification report (P10.5)")
struct PullRequestVerificationReportTests {
    private func openedBody(recording clauses: [ClauseVerificationRecord]?) async throws -> String {
        let local = TestGitRepo(name: "pr-verify-local-\(UUID().uuidString.prefix(8))")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        if let clauses {
            try env.journal.recordFeatureVerification(NewFeatureVerification(
                featureID: feature.id, cycleID: cycleID, route: "codex/gpt-5.4/high",
                nightID: env.context.night.id, runID: env.runID, clauses: clauses
            ))
        }
        let url = "https://github.com/summerhammer/backend/pull/1"
        let stub = StubPublicationAdapter(result: .success(.opened(url: url)))
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        _ = try await seam.open(laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil)
        return try #require(await stub.calls.first?.body)
    }

    @Test("A recorded Verification is in the body, with its limitation")
    func bodyCarriesTheReport() async throws {
        let body = try await openedBody(recording: [
            ClauseVerificationRecord(
                issueID: "BACK-1", cid: "c1", level: "card", text: "Returns 404.", locationID: "epic/story",
                citationProvenance: "Author-supplied", verdict: .met, whatWasChecked: "read the handler",
                interpretation: "path parameter", judgedBy: .agent
            )
        ])
        #expect(body.contains("## Verification, clause by clause"))
        #expect(body.contains("BACK-1 c1 · Returns 404. · Spec Citation (epic/story) · [Author-supplied] · met"))
        #expect(body.contains("auditable, not sound"))
    }

    @Test("With no Verification recorded the body has no report section")
    func bodyWithoutTheReport() async throws {
        let body = try await openedBody(recording: nil)
        #expect(!body.contains("Verification, clause by clause"))
        #expect(!body.contains("Known limitation"))
    }
}
