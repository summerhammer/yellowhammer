import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.4: the land Act's real pull request seam, exercised directly (as ``LandActPushTests``
// exercises ``FeatureBranchLanePush``) rather than through the full `EngineInvocation`.

@Suite("Land Act pull request (P10.4)")
struct FeatureBranchPullRequestTests {
    @Test("Opening succeeds: records the pull request once, links the Feature Issue and each done Card")
    func opensAndLinks() async throws {
        let local = TestGitRepo(name: "pr-ok-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)
        #expect(outcome.detail == "https://github.com/summerhammer/backend/pull/1")

        let recorded = try env.journal.pullRequest(featureID: feature.id, repository: "backend")
        #expect(recorded?.url == "https://github.com/summerhammer/backend/pull/1")

        let calls = await stub.calls
        #expect(calls.count == 1)
        #expect(calls[0].owner == "summerhammer")
        #expect(calls[0].repository == "backend")
        #expect(calls[0].head == "yh-proj-feat")

        let attachments = await env.board.attachments
        #expect(attachments.contains { $0.issue.rawValue == "FEAT-1" })
        #expect(attachments.contains { $0.issue.rawValue == "BACK-1" })
    }

    @Test("Partial Landing body: hole Card, its clauses, the carried-forward Card, and k/N, u_count, c_count")
    func partialLandingBodyContent() async throws {
        let local = TestGitRepo(name: "pr-partial-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let cycleID = try Self.setUpPartialLandingFixture(env.journal)

        let (feature, _) = try #require(try env.journal.inFlightFeature())
        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)

        let calls = await stub.calls
        let body = try #require(calls.first?.body)

        // The hole Card, by title.
        #expect(body.contains("Fix the endpoint"))
        #expect(!body.contains("BACK-2"))
        // Both clause texts, quoted with their Spec Citation, marked unmet.
        #expect(body.contains("The endpoint returns 404 for a missing id."))
        #expect(body.contains("feature-authoring/write-a-card#dod-1"))
        #expect(body.contains("The response is logged at info level."))
        #expect(body.contains("feature-authoring/write-a-card#dod-2"))
        // The Waiting on You Card is named in the carried-forward list.
        #expect(body.contains("Carried forward"))
        #expect(body.contains("BACK-3"))
        // k of N: 1 of 3 landed. u_count: 2 unmet clauses. c_count: 2 incomplete Cards (Blocked + Waiting
        // on You) carried forward, per the fixed line 2's "unfinished Cards" wording (see PullRequestBody).
        #expect(body.contains("1 of 3 Cards landed"))
        #expect(body.contains("2 Definition of Done clauses remain unmet"))
        #expect(body.contains("2 unfinished Cards are carried forward"))
        #expect(body.contains("1 waiting on you"))
    }

    /// A fixture Cycle for the Partial Landing body test: one Done Card, one Blocked hole Card with
    /// two Definition of Done clauses, and one Waiting on You Card. Returns the Cycle id.
    static func setUpPartialLandingFixture(_ journal: JournalStore) throws -> Int64 {
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue))
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        try insertReconcilerCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done)
        try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .blocked,
            title: "Fix the endpoint"
        )
        try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-3", repository: "backend", state: .waitingOnYou
        )
        try journal.insertClause(JournalStore.NewClause(
            cid: "c1", issueID: "BACK-2", level: "card", text: "The endpoint returns 404 for a missing id.",
            locationID: "feature-authoring/write-a-card#dod-1", provenance: "Author-supplied",
            citationProvenance: "Author-supplied"
        ))
        try journal.insertClause(JournalStore.NewClause(
            cid: "c2", issueID: "BACK-2", level: "card", text: "The response is logged at info level.",
            locationID: "feature-authoring/write-a-card#dod-2", provenance: "Author-supplied",
            citationProvenance: "Author-supplied"
        ))
        return cycleID
    }

    @Test("Each Card's line in the body names its route, a check result, and its Round count")
    func perCardRouteCheckRoundCountAppear() async throws {
        let local = TestGitRepo(name: "pr-cardline-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()
        let card = try #require(try env.journal.card(issueID: "BACK-1"))

        let attemptID = try env.journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO attempt (card_id, budget_epoch, route_cli, route_model, route_effort, started_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [card.id, 0, "claude", "sonnet", "medium", JournalStore.timestamp(landEpoch)]
            )
            return db.lastInsertedRowID
        }
        try env.journal.write { db in
            try db.execute(
                sql: "INSERT INTO round (attempt_id, lens, verdict, created_at) VALUES (?, ?, ?, ?)",
                arguments: [attemptID, "check", "passed", JournalStore.timestamp(landEpoch)]
            )
        }

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

        let calls = await stub.calls
        let body = try #require(calls.first?.body)
        // Route, a check result, and the Round count each appear for the Card.
        #expect(body.contains("claude/sonnet"))
        #expect(body.contains("checks: passed"))
        #expect(body.contains("1 round(s)"))
    }

    @Test("A second call for an already-recorded pull request calls Publication nothing")
    func secondCallCallsNothing() async throws {
        let local = TestGitRepo(name: "pr-recorded-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        try env.journal.recordPullRequest(
            featureID: feature.id, repository: "backend", url: "https://github.com/summerhammer/backend/pull/9",
            nightID: env.context.night.id, runID: env.runID, now: landEpoch
        )

        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/99"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)
        #expect(outcome.detail == "https://github.com/summerhammer/backend/pull/9")
        let calls = await stub.calls
        #expect(calls.isEmpty)
    }

    @Test("alreadyOpen is recorded with a nil URL, and no link is posted")
    func alreadyOpenRecordsNoLink() async throws {
        let local = TestGitRepo(name: "pr-alreadyopen-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let stub = StubPublicationAdapter(result: .success(.alreadyOpen))
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)

        let recorded = try env.journal.pullRequest(featureID: feature.id, repository: "backend")
        #expect(recorded != nil)
        #expect(recorded?.url == nil)

        let attachments = await env.board.attachments
        #expect(attachments.isEmpty)
    }

    @Test("A credentials error is reported as a failed step and comments on the Feature Issue, naming the repository")
    func credentialsErrorComments() async throws {
        let local = TestGitRepo(name: "pr-creds-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature()

        let stub = StubPublicationAdapter(
            result: .failure(.credentialsMissingOrInsufficient("no token"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch })
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(!outcome.opened)

        let recorded = try env.journal.pullRequest(featureID: feature.id, repository: "backend")
        #expect(recorded == nil)

        let comments = await env.board.comments
        #expect(comments.contains {
            $0.issue.rawValue == "FEAT-1" && $0.body.contains("backend") && $0.body.contains("credentials")
        })
    }
}

/// A stub `Publication` that returns one scripted result and records every draft it was called with.
actor StubPublicationAdapter: Publication {
    enum Result {
        case success(PullRequestReceipt)
        case failure(PublicationError)
    }

    private let result: Result
    private(set) var calls: [PullRequestDraft] = []

    init(result: Result) {
        self.result = result
    }

    func openPullRequest(_ draft: PullRequestDraft) async throws(PublicationError) -> PullRequestReceipt {
        calls.append(draft)
        switch result {
        case .success(let receipt):
            return receipt
        case .failure(let error):
            throw error
        }
    }
}
