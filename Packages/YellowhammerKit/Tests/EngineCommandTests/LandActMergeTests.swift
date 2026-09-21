import Domain
@testable import Engine
import Foundation
import Repositories
@testable import Journal
import Testing

extension LandActPushTests {
    @Test("A concrete merge conflict records paths, preserves the Feature block, and does not gate landing")
    func concreteMergeConflictReportsAndContinues() async throws {
        let local = TestGitRepo(name: "merge-land-conflict-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(filename: "shared.txt", content: "base", message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "shared.txt", content: "feature", message: "feature edit")
        _ = await local.run(["checkout", "main"])
        let mainSHA = try await local.commit(filename: "shared.txt", content: "main", message: "main edit")
        let remote = TestGitRepo(name: "merge-land-conflict-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)
        _ = await local.run(["push", "origin", "main"])
        let branchSHA = try #require(await local.revParse("yh-proj-feat"))

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        let description = "authored prose\n\n\(ManagedBlockFence.initialDescription(rendered: "existing"))"
        await env.board.seed(issue: "FEAT-1", description: description)
        let (feature, cycleID) = try env.setUpFeature()
        let workspace = ReconcilerFakeWorkspace()
        let context = mergeContext(env, commit: mainSHA, workspace: workspace)
        try env.journal.recordWorktree(
            featureID: feature.id, repository: "backend", worktreeID: "merge-wt",
            path: local.path, runID: env.runID
        )
        let statusBefore = await local.run(["status", "--porcelain"]).stdout
        let refsBefore = await local.run(["for-each-ref"]).stdout
        let headBefore = await local.revParse("HEAD")
        let indexBefore = try Data(contentsOf: local.url.appendingPathComponent(".git/index"))
        let log = LandCallLog()
        let land = LandAct(
            mergeTest: FeatureBranchLaneMergeTest(), push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log)
        )
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: context
        )

        #expect(failure == nil)
        #expect(log.all == ["push:backend", "openPullRequest:backend"])
        #expect(workspace.removeCalls.map(\.id) == [WorktreeID(rawValue: "merge-wt")])
        #expect(branchSHA != mainSHA)
        let statusAfter = await local.run(["status", "--porcelain"]).stdout
        let refsAfter = await local.run(["for-each-ref"]).stdout
        let headAfter = await local.revParse("HEAD")
        #expect(statusBefore == statusAfter)
        #expect(refsBefore == refsAfter)
        #expect(headBefore == headAfter)
        #expect(indexBefore == (try Data(contentsOf: local.url.appendingPathComponent(".git/index"))))
        try await assertConflictReports(env, context: context)
    }

    private func assertConflictReports(_ env: Environment, context: ActContext) async throws {
        let event = try #require(try env.journal.events(ofType: .mainlineConflictDetected).last)
        guard case .mainlineConflictDetected(_, let repository, let paths) = event.event else {
            Issue.record("expected a Mainline Conflict event")
            return
        }
        #expect(repository == "backend")
        #expect(paths == ["shared.txt"])
        let issue = await env.board.issue(BoardObjectID(rawValue: "FEAT-1"))
        #expect(issue?.description?.contains("authored prose") == true)
        #expect(issue?.description?.contains("[conflict: backend]") == true)
        #expect(issue?.description?.contains("shared.txt") == true)
        #expect(issue?.description?.contains("existing") == true)
        #expect(issue?.description?.contains("as of Night \(landNightStart)") == true)
        let card = try #require(try env.journal.card(issueID: "BACK-1"))
        #expect(card.state == CardState.done)
        let boards = try await makeBoards()
        let outbox = try #require(context.outbox)
        let maintenance = NightCardMaintenance(
            journal: env.journal, outbox: outbox, provisioning: boards.provisioning
        )
        _ = try await maintenance.open(night: context.night)
        let night = try #require(try env.journal.night(id: context.night.id))
        _ = try await maintenance.acceptCompletion(night: night)
        _ = try await maintenance.deliverCompletion(night: night)
        let nightIssue = try #require(night.nightCardIssueID)
        let summary = await env.board.issue(BoardObjectID(rawValue: nightIssue))?.description
        #expect(summary?.contains("shared.txt") == true)
        #expect(summary?.contains("as of Night \(landNightStart)") == true)
    }

    @Test("Merge results distinguish missing snapshots, local fallbacks and missing branches from clean",
          arguments: ["no snapshot", "local fallback", "missing branch", "clean"])
    func concreteMergeOutcome(scenario: String) async throws {
        let local = TestGitRepo(name: "merge-land-untestable-local")
        await local.initRepo(defaultBranch: "main")
        let mainSHA = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feature.txt", content: "feature", message: "feature")
        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(
            rendered: "Mainline merge test for `backend`: [conflict: backend] old.txt"
        ))
        let branch = scenario == "missing branch" ? FeatureBranch(rawValue: "missing") : landBranch
        let (feature, cycleID) = try env.setUpFeature(branch: branch)
        let context = scenario == "no snapshot" ? env.context : mergeContext(
            env, commit: mainSHA, ref: scenario == "local fallback" ? "refs/heads/main" : "refs/remotes/origin/main"
        )
        let outcome = try await FeatureBranchLaneMergeTest().test(
            LandActLaneContext(
                act: context, feature: feature, cycleID: cycleID,
                lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID))
            )
        )
        #expect(outcome.untestable == (scenario != "clean"))
        #expect(!outcome.conflict)
        if scenario == "clean" {
            #expect(outcome.detail?.contains("clean is not a claim that merging is safe") == true)
            #expect(outcome.detail?.contains("may be stale") == true)
        } else {
            #expect(outcome.detail?.contains("untestable") == true)
        }
        let description = try #require(await env.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(!description.contains("[conflict: backend]"))
        #expect(description.contains("as of Night \(landNightStart)"))
    }

    private func mergeContext(
        _ env: Environment, commit: String, ref: String = "refs/remotes/origin/main",
        workspace: (any Workspace)? = nil
    ) -> ActContext {
        ActContext(
            act: env.context.act, mode: env.context.mode, trigger: env.context.trigger, runID: env.runID,
            journal: env.journal, night: env.context.night, outbox: env.context.outbox,
            mainlines: ResolvedMainlines(workingRepos: [
                "backend": ResolvedMainline(repository: "backend", defaultBranch: "main", ref: ref, commit: commit)
            ]), workspace: workspace, repositories: env.context.repositories
        )
    }
}
