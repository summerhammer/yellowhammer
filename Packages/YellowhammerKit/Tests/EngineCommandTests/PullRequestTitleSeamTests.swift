import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P19.2 through the seam: only the string handed to the Publication stub is asserted.

@Suite("Pull request title through the land Act seam (P19.2)")
struct PullRequestTitleSeamTests {
    private static func makeRepo(name: String) async -> (TestGitRepo, Repo) {
        let local = TestGitRepo(name: name)
        await local.initRepo(defaultBranch: "main")
        _ = try? await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")
        return (local, Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main"))
    }

    private static func open(
        _ env: Environment, context: ActContext? = nil, feature: FeatureRecord, cycleID: Int64,
        template: MessageTemplate = .default(.pullRequestTitle), changeType: ChangeType = .feat
    ) async throws -> PullRequestDraft {
        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(
            publication: stub, clock: { landEpoch }, titleTemplate: template, changeType: changeType,
            projectID: "proj"
        )
        let laneContext = LandActLaneContext(
            act: context ?? env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        _ = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        return try #require(await stub.calls.first)
    }

    private static func insertFeatureClause(_ journal: JournalStore, cid: String, citation: String) throws {
        try journal.insertClause(
            JournalStore.NewClause(
                cid: cid, issueID: "FEAT-1", level: "feature", text: "Clause \(cid)", locationID: citation,
                provenance: "Author-supplied", citationProvenance: "Author-supplied"
            ),
            now: landEpoch
        )
    }

    @Test("description order of the clause markers decides the tie; {key} is the human identifier")
    func descriptionOrderAndKey() async throws {
        let (local, repo) = await Self.makeRepo(name: "title-desc")
        _ = local
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        for (cid, citation) in [("c1", "auth/a"), ("c2", "auth/b"), ("c3", "billing/c"), ("c4", "billing/d")] {
            try Self.insertFeatureClause(env.journal, cid: cid, citation: citation)
        }
        // cid order c1..c4 would tie 2-2 and give `auth`; the description lists billing's clauses first.
        let description = """
        - [ ] <!-- yh:clause:c3 --> Clause c3 (billing/c)
        - [ ] <!-- yh:clause:c4 --> Clause c4 (billing/d)
        - [ ] <!-- yh:clause:c1 --> Clause c1 (auth/a)
        - [ ] <!-- yh:clause:c2 --> Clause c2 (auth/b)
        """
        let object = BoardObject(
            id: BoardObjectID(rawValue: "FEAT-1"), key: "YLH-42", title: "Add login", description: description,
            workflowState: BoardWorkflowState(id: BoardObjectID(rawValue: "s"), name: "Todo"), labels: [],
            parent: nil, url: "https://linear.app/x/issue/YLH-42", createdAt: landEpoch, updatedAt: landEpoch
        )
        let reading = FakeReadingBoard([])
        await reading.scriptObjectPages([.success(BoardPage(objects: [object], nextCursor: nil))])
        let provisioning = FakeProvisioningBoard(project: nil)
        let context = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: env.runID, journal: env.journal,
            night: env.context.night, outbox: env.context.outbox,
            board: ActBoard(reading: reading, writing: env.board, provisioning: provisioning),
            mainlines: ResolvedMainlines(), repositories: env.context.repositories
        )
        let template = try MessageTemplate("{type}{scope}: {title} [{key}]", kind: .pullRequestTitle)
        let draft = try await Self.open(
            env, context: context, feature: feature, cycleID: cycleID, template: template
        )
        #expect(draft.title == "feat(billing): Add login [YLH-42]")
    }

    @Test("without a description, clauses are in numeric cid order (c2 before c10), not lexical")
    func numericCidOrderWithoutDescription() async throws {
        let (local, repo) = await Self.makeRepo(name: "title-numeric")
        _ = local
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        for number in 1...12 {
            let citation = switch number {
            case 2: "auth/a"
            case 10: "billing/b"
            default: "G\(number)"
            }
            try Self.insertFeatureClause(env.journal, cid: "c\(number)", citation: citation)
        }
        // 1-1 tie: numeric order puts auth's c2 first; lexical order would put billing's c10 first.
        let draft = try await Self.open(env, feature: feature, cycleID: cycleID)
        #expect(draft.title == "feat(auth): FEAT-1")
    }

    @Test("Partial Landing: {partial} follows the body; a template without it has no prefix, body is unchanged")
    func partialLanding() async throws {
        let (local, repo) = await Self.makeRepo(name: "title-partial")
        _ = local
        let defaultEnv = try await Environment.make(repos: [repo])
        await defaultEnv.board.seed(issue: "FEAT-1", description: nil)
        let defaultCycle = try FeatureBranchPullRequestTests.setUpPartialLandingFixture(defaultEnv.journal)
        let (defaultFeature, _) = try #require(try defaultEnv.journal.inFlightFeature())
        let withPrefix = try await Self.open(defaultEnv, feature: defaultFeature, cycleID: defaultCycle)
        #expect(withPrefix.title == "feat: partial landing: FEAT-1")

        let bareEnv = try await Environment.make(repos: [repo])
        await bareEnv.board.seed(issue: "FEAT-1", description: nil)
        let bareCycle = try FeatureBranchPullRequestTests.setUpPartialLandingFixture(bareEnv.journal)
        let (bareFeature, _) = try #require(try bareEnv.journal.inFlightFeature())
        let bare = try await Self.open(
            bareEnv, feature: bareFeature, cycleID: bareCycle,
            template: try MessageTemplate("{title}", kind: .pullRequestTitle)
        )
        #expect(bare.title == "FEAT-1")
        #expect(!bare.title.contains("partial landing: "))

        // The Partial Landing announcement stays in the body's first two lines, whatever the template.
        let lines = bare.body.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasPrefix("**partial landing · 1 of 3 Cards landed"))
        #expect(lines[1].contains("2 unfinished Cards are carried forward"))
        #expect(bare.body == withPrefix.body)
    }

    @Test("the body is identical whichever template renders the title")
    func bodyIgnoresTemplate() async throws {
        let (local, repo) = await Self.makeRepo(name: "title-body")
        _ = local
        var bodies: [String] = []
        for text in ["{type}{scope}: {title}", "[{project}] {repository} {branch}"] {
            let env = try await Environment.make(repos: [repo])
            await env.board.seed(issue: "FEAT-1", description: nil)
            let (feature, cycleID) = try env.setUpFeature()
            let template = try MessageTemplate(text, kind: .pullRequestTitle)
            let draft = try await Self.open(env, feature: feature, cycleID: cycleID, template: template)
            bodies.append(draft.body)
        }
        #expect(bodies[0] == bodies[1])
    }
}
