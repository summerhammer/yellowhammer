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
        // P19.7 (risks OQ108): the note sits beside the bold Roll-up sentence, which is unchanged.
        let firstLine = try #require(body.components(separatedBy: "\n").first)
        #expect(firstLine.hasSuffix("0 of 1 merged · 1 waiting on you** [no pull request: mobile]"))
        #expect(firstLine.hasPrefix("**partial · "))
    }

    // MARK: - The note on the rendered body (P19.7; risks OQ108)

    private static func bodyInput(
        cards: [PullRequestBodyCard], noPullRequest: [String]? = nil
    ) -> PullRequestBodyInput {
        let verdict = PullRequestBodyMergeVerdict(conflict: false, untestable: true)
        guard let noPullRequest else {
            return PullRequestBodyInput(
                featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-09-16",
                repository: "backend", pushedRepositoryCount: 1, mergedCount: 0, cycleCards: cards,
                mergeVerdict: verdict, unmetClauses: []
            )
        }
        return PullRequestBodyInput(
            featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-09-16",
            repository: "backend", pushedRepositoryCount: 1, mergedCount: 0, cycleCards: cards,
            mergeVerdict: verdict, unmetClauses: [], noPullRequestRepositories: noPullRequest
        )
    }

    private static let doneCard = PullRequestBodyCard(
        title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
    )
    private static let waitingCard = PullRequestBodyCard(
        title: "MOB-1", repository: "backend", state: .waitingOnYou, routeSummary: "r", checkSummary: "c",
        roundCount: 1, waitingReason: .question
    )

    @Test("A partial body's line 1 is the unchanged bold sentence followed by one sorted note per repository")
    func partialBodyCarriesNotes() {
        let cards = [Self.doneCard, Self.waitingCard]
        let plain = PullRequestBody.render(Self.bodyInput(cards: cards))
        let noted = PullRequestBody.render(Self.bodyInput(cards: cards, noPullRequest: ["web", "mobile"]))

        let plainLine = plain.components(separatedBy: "\n")[0]
        let notedLine = noted.components(separatedBy: "\n")[0]
        #expect(plainLine == "**partial · 1 of 2 Cards landed · 0 of 1 merged · 1 waiting on you**")
        #expect(notedLine == plainLine + " [no pull request: mobile] [no pull request: web]")
        // Only line 1 differs.
        #expect(plain.components(separatedBy: "\n").dropFirst() == noted.components(separatedBy: "\n").dropFirst())
    }

    @Test("A complete body has no Roll-up sentence, so it is byte-identical with and without the notes")
    func completeBodyIgnoresNotes() {
        let cards = [Self.doneCard]
        let plain = PullRequestBody.render(Self.bodyInput(cards: cards))
        let noted = PullRequestBody.render(Self.bodyInput(cards: cards, noPullRequest: ["mobile"]))
        #expect(plain == noted)
        #expect(!noted.contains("[no pull request:"))
    }
}
