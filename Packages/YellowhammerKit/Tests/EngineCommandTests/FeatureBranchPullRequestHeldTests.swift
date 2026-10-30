import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// spec ruling OQ182 (2026-10-22), item 4: the land Act's real pull request seam names each held
// Work Card, with the Work Card it waits on, in the Partial Landing body — and a lane whose only
// unfinished Work Card is held still renders a Partial Landing, never a complete one.

@Suite("Land Act pull request: held Work Cards (OQ182 item 4)")
struct FeatureBranchPullRequestHeldTests {
    private func openedBody(
        _ env: LandPushTestEnvironment, feature: FeatureRecord, cycleID: Int64
    ) async throws -> String {
        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/backend/pull/1"))
        )
        let seam = FeatureBranchPullRequest(publication: stub, clock: { landEpoch }, remoteTip: .at("deadbeef"))
        let laneContext = LandActLaneContext(
            act: env.context, feature: feature, cycleID: cycleID,
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
        )
        let outcome = try await seam.open(
            laneContext, push: LanePushOutcome(pushed: true, commit: "deadbeef"), mergeOutcome: nil
        )
        #expect(outcome.opened)
        return try #require(await stub.calls.first?.body)
    }

    @Test("A held Card is named, held behind its holder's title, in both the incomplete and carried-forward sections")
    func heldCardNamedInBothSections() async throws {
        let local = TestGitRepo(name: "pr-held-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)

        let featureID = try insertReconcilerFeature(env.journal, issueID: "FEAT-1")
        try env.journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(env.journal, featureID: featureID)
        // DOCS-1 is Blocked (not Done): it holds DOCS-2, which stays Todo.
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-1", repository: "backend", state: .blocked,
            title: "Fix the endpoint"
        )
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-2", repository: "backend", state: .todo,
            title: "Document the endpoint"
        )

        let (feature, _) = try #require(try env.journal.inFlightFeature())
        let body = try await openedBody(env, feature: feature, cycleID: cycleID)

        #expect(body.hasPrefix("**partial · "))
        #expect(body.contains("- Document the endpoint [backend]: Todo — held behind \"Fix the endpoint\""))
        #expect(body.contains("- Document the endpoint [backend] — held behind \"Fix the endpoint\""))
        // Both DOCS-1 (Blocked) and DOCS-2 (held) are carried forward.
        #expect(body.contains("2 unfinished Cards are carried forward"))
    }

    @Test("A held Card's own Definition of Done clauses appear in the unmet-clauses list")
    func heldCardsClausesAppearAsUnmet() async throws {
        let local = TestGitRepo(name: "pr-held-clauses-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)

        let featureID = try insertReconcilerFeature(env.journal, issueID: "FEAT-1")
        try env.journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(env.journal, featureID: featureID)
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-1", repository: "backend", state: .blocked,
            title: "Fix the endpoint"
        )
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-2", repository: "backend", state: .todo,
            title: "Document the endpoint"
        )
        try env.journal.insertClause(JournalStore.NewClause(
            cid: "c1", issueID: "DOCS-2", level: "card", text: "The endpoint's new field is documented.",
            locationID: "feature-authoring/write-a-card#dod-1", provenance: "Author-supplied",
            citationProvenance: "Author-supplied"
        ))

        let (feature, _) = try #require(try env.journal.inFlightFeature())
        let body = try await openedBody(env, feature: feature, cycleID: cycleID)

        #expect(body.contains("Document the endpoint: \"The endpoint's new field is documented.\""))
        #expect(body.contains("feature-authoring/write-a-card#dod-1"))
    }

    @Test("A Card held behind a Shelved predecessor renders a Partial Landing, never a complete one")
    func heldBehindShelvedPredecessorForcesPartialLanding() async throws {
        let local = TestGitRepo(name: "pr-held-shelved-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)

        let featureID = try insertReconcilerFeature(env.journal, issueID: "FEAT-1")
        try env.journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(env.journal, featureID: featureID)
        // Every other Card in the Cycle is Done; the one unfinished Card is held behind a Shelved
        // predecessor in its own sequence.
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
        )
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-1", repository: "docs", state: .shelved,
            title: "Draft the guide"
        )
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-2", repository: "docs", state: .todo,
            title: "Publish the guide"
        )

        let (feature, _) = try #require(try env.journal.inFlightFeature())
        let body = try await openedBody(env, feature: feature, cycleID: cycleID)

        #expect(body.hasPrefix("**partial · "))
        #expect(body.contains("0 blocked"))
        #expect(body.contains("- Publish the guide [docs]: Todo — held behind \"Draft the guide\""))
    }

    @Test("A Card held behind a predecessor removed from the board renders a Partial Landing, naming the holder")
    func heldBehindRemovedPredecessorForcesPartialLanding() async throws {
        let local = TestGitRepo(name: "pr-held-removed-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        await local.addRemote(url: "git@github.com:summerhammer/backend.git")

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)

        let featureID = try insertReconcilerFeature(env.journal, issueID: "FEAT-1")
        try env.journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: landBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(env.journal, featureID: featureID)
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .done
        )
        let removedHolderID = try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-1", repository: "docs", state: .done,
            title: "Draft the guide"
        )
        try insertReconcilerCard(
            env.journal, cycleID: cycleID, issueID: "DOCS-2", repository: "docs", state: .todo,
            title: "Publish the guide"
        )
        try env.journal.write { db in
            try db.execute(
                sql: "UPDATE card SET removed_from_board = ? WHERE id = ?",
                arguments: [CardRemoval.trashed.rawValue, removedHolderID]
            )
        }

        let (feature, _) = try #require(try env.journal.inFlightFeature())
        let body = try await openedBody(env, feature: feature, cycleID: cycleID)

        #expect(body.hasPrefix("**partial · "))
        // A removed Card (OQ142) is set aside: it is never listed as a Card of its own — no
        // "Cards in this repository" or clause entry names it — but it is still the Work Card DOCS-2
        // waits on, so its title appears in that pointer.
        #expect(!body.contains("- Draft the guide ["))
        #expect(body.contains("- Publish the guide [docs]: Todo — held behind \"Draft the guide\""))
        #expect(body.contains("- Publish the guide [docs] — held behind \"Draft the guide\""))
    }
}
