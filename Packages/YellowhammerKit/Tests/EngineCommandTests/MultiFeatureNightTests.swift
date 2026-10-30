import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// shift-scheduling/fire-an-act-on-schedule and feature-authoring/select-the-next-feature (roadmap P23.6): a
// Night that lands a Feature, authors the next one on top of it, lands that one stacked on the first, sees the
// first merged, and lands a third on the second. Throwaway git repositories, a stub Workspace that honours
// `--base-branch`, a stub Publication and a fixtured verification verdict; the model-authored parts (selection,
// breakdown, the worker's diff) are replaced by the rows they would have written, and only engine-run facts are
// asserted: Journal rows, events, refs and the drafts handed to the Publication stub.

/// Stands in for Orca ADE: creates a real detached `git worktree` at the requested base, as the real one does.
private final class FixtureWorkspace: Workspace, Sendable {
    private let created = Mutex<[String?]>([])
    private let baseDirectory: URL
    private let git = GitRunner()

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    var baseBranches: [String?] { created.withLock { $0 } }

    func registeredRepositoryPaths() async throws(WorkspaceError) -> [String] { [] }
    func registerRepository(path: String) async throws(WorkspaceError) {}
    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }
    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {}

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        created.withLock { $0.append(baseBranch) }
        let directory = baseDirectory.appending(component: name, directoryHint: .isDirectory)
        let result = await git.run([
            "-C", repositoryPath, "worktree", "add", "--detach", directory.path, baseBranch ?? "HEAD"
        ])
        guard result.isSuccess else { throw .refused(code: "git", message: result.stderr) }
        return WorkspaceWorktree(
            id: WorktreeID(rawValue: "ow-\(name)"), path: directory.path, branch: name, displayName: name
        )
    }
}

private struct FeatureSeed {
    let id: Int64
    let issueID: String
    let branch: String
}

/// The Night's world: one repository `repo-a` with a bare remote, the land Act's environment and the stub Workspace.
private final class NightWorld {
    let scratch = FileManager.default.temporaryDirectory
        .appending(component: "yh-multi-feature-night-\(UUID().uuidString)", directoryHint: .isDirectory)
    let local = TestGitRepo(name: "mfn-local")
    let remote = TestGitRepo(name: "mfn-remote")
    let repo: Repo
    let env: Environment
    let workspace: FixtureWorkspace
    let mainline: String

    deinit { try? FileManager.default.removeItem(at: scratch) }

    init() async throws {
        await local.initRepo()
        mainline = try await local.commit(filename: "base.txt", content: "base", message: "mainline")
        await local.run(["update-ref", "refs/remotes/origin/main", mainline])
        await remote.initRepo(bare: true)
        // The pull request seam needs a GitHub origin; pushes go to the local bare repository.
        await local.addRemote(url: "git@github.com:summerhammer/repo-a.git")
        await local.run(["remote", "set-url", "--push", "origin", remote.path])
        repo = Repo(name: "repo-a", path: local.path, role: .backend, defaultBranch: "main")
        env = try await Environment.make(repos: [repo])
        let worktrees = scratch.appending(component: "worktrees")
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        workspace = FixtureWorkspace(baseDirectory: worktrees)
        for issue in ["FEAT-1", "FEAT-2", "FEAT-3"] {
            await env.board.seed(issue: issue, description: ManagedBlockFence.initialDescription(rendered: "x"))
        }
    }

    func context(act: Act, runID: RunID, mainlineCommit: String) -> ActContext {
        ActContext(
            act: act, mode: .real, trigger: .scheduled, runID: runID, journal: env.journal, night: env.context.night,
            outbox: act == .land ? env.context.outbox : nil,
            mainlines: ResolvedMainlines(workingRepos: [
                "repo-a": ResolvedMainline(
                    repository: "repo-a", defaultBranch: "main", ref: "refs/remotes/origin/main",
                    commit: mainlineCommit
                )
            ]),
            workspace: workspace, repositories: env.context.repositories
        )
    }

    func landContext() -> ActContext { context(act: .land, runID: env.runID, mainlineCommit: mainline) }

    private func clause(_ issue: String) -> ClauseVerificationRecord {
        ClauseVerificationRecord(
            issueID: issue, cid: "c1", level: "card", text: "Clause.", locationID: "epic/story",
            citationProvenance: "machine-found", verdict: .met, whatWasChecked: "checked", interpretation: "read",
            judgedBy: .agent
        )
    }

    /// The rows authoring leaves for a Feature with one Done Card in `repo-a`, plus its recorded Verification.
    func seedFeature(issueID: String, branch: String, bases: [FeatureBaseRecord] = []) throws -> Int64 {
        let journal = env.journal
        let featureID = try insertReconcilerFeature(journal, issueID: issueID)
        try journal.recordWorktreeName(featureID: featureID, worktreeName: WorktreeName(rawValue: branch))
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "CARD-\(issueID)", repository: "repo-a", state: .done
        )
        try recordTouchedRepositories(journal, featureID: featureID, repositories: ["repo-a"])
        // Worktree allocation records the Feature Branch of each touched repository.
        try journal.write { db in
            try db.execute(
                sql: "UPDATE feature_repository SET branch = ? WHERE feature_id = ?", arguments: [branch, featureID]
            )
        }
        if !bases.isEmpty { try journal.recordFeatureBases(featureID: featureID, bases: bases) }
        try journal.recordFeatureVerification(NewFeatureVerification(
            featureID: featureID, cycleID: cycleID, route: nil, nightID: env.context.night.id, runID: env.runID,
            clauses: [clause(issueID)]
        ))
        return featureID
    }

    /// Builds `branch` from `base` with one commit and runs one land firing over it; returns the pull request
    /// drafts the firing handed to the Publication stub and the branch's tip.
    func buildAndLand(
        branch: String, from base: String, number: Int
    ) async throws -> (drafts: [PullRequestDraft], tip: String) {
        await local.run(["checkout", "-b", branch, base])
        let tip = try await local.commit(filename: "\(branch).txt", content: branch, message: branch)
        let stub = StubPublicationAdapter(
            result: .success(.opened(url: "https://github.com/summerhammer/repo-a/pull/\(number)"))
        )
        let act = LandAct(
            push: FeatureBranchLanePush(credential: { nil }),
            openPullRequest: FeatureBranchPullRequest(
                publication: stub, clock: { landEpoch },
                remoteTip: .rewriting("git@github.com:summerhammer/repo-a.git", to: remote.path)
            ),
            verification: StubVerification(log: LandCallLog(), verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: CycleArchive()
        )
        try await act.run(landContext())
        return (await stub.calls, tip)
    }

    func head(of worktree: WorktreeRecord) async -> String {
        await GitRunner().run(["-C", worktree.path, "rev-parse", "HEAD"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Merges `branch` into mainline with a merge commit and refreshes `refs/remotes/origin/main`.
    func mergeIntoMainline(_ branch: String) async throws -> String {
        await local.run(["checkout", "main"])
        await local.run(["merge", "--no-ff", branch, "-m", "merge \(branch)"])
        let merged = try #require(await local.revParse("HEAD"))
        await local.run(["update-ref", "refs/remotes/origin/main", merged])
        return merged
    }
}

@Suite("A two-Feature Night over fixture repositories (P23.6)")
struct MultiFeatureNightTests {
    @Test("F1 lands on main, F2 is authored and cut from F1's tip and lands stacked, F1 merges, F3 stacks on F2")
    func twoFeatureNight() async throws {
        let world = try await NightWorld()
        let journal = world.env.journal

        // F1: authored, built (a commit on its Feature Branch), landed against main and archived.
        let first = try world.seedFeature(issueID: "FEAT-1", branch: "yh-f1")
        let landedFirst = try await world.buildAndLand(branch: "yh-f1", from: world.mainline, number: 7)
        #expect(landedFirst.drafts.map(\.base) == ["main"])
        #expect(landedFirst.drafts.first?.body.contains("Stacked on") == false)
        #expect(try journal.isCycleLanded(cycleID: try #require(try journal.cycleID(featureID: first))))
        #expect(try journal.inFlightCycleID() == nil)
        #expect(await world.local.revParse("refs/yellowhammer/landed/yh-f1") == landedFirst.tip)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["FEAT-1"])

        // The next author firing: F1 holds one slot of U, so F2 is selected against F1's pinned tip.
        let bases = try await AuthoringBases.fromStack(context: world.landContext())
        #expect(bases.faults.isEmpty)
        #expect(bases.records == [FeatureBaseRecord(
            repository: "repo-a", baseRef: "refs/yellowhammer/landed/yh-f1", baseCommit: landedFirst.tip,
            stackedOnFeatureID: first
        )])
        let second = try world.seedFeature(issueID: "FEAT-2", branch: "yh-f2", bases: bases.records)

        // F2's Worktree is cut from C1, not from mainline.
        let allocator = WorktreeAllocator(workspace: world.workspace, journal: journal, runID: world.env.runID)
        let allocated = try await allocator
            .allocate(featureID: second, worktreeName: WorktreeName(rawValue: "yh-f2"), repos: [world.repo])
        #expect(world.workspace.baseBranches == ["refs/yellowhammer/landed/yh-f1"])
        #expect(await world.head(of: try #require(allocated["repo-a"])) == landedFirst.tip)

        try await landSecondMergeFirstLandThird(world, first: first, second: second, firstTip: landedFirst.tip)
    }

    private func landSecondMergeFirstLandThird(
        _ world: NightWorld, first: Int64, second: Int64, firstTip: String
    ) async throws {
        let journal = world.env.journal

        // F2 builds a commit on top of C1 and lands with PR base = b1 and the stack notice.
        let landedSecond = try await world.buildAndLand(branch: "yh-f2", from: firstTip, number: 8)
        #expect(landedSecond.drafts.map(\.base) == ["yh-f1"])
        #expect(landedSecond.drafts.first?.body.contains("Stacked on #7") == true)
        #expect(try journal.events(ofType: .pullRequestStacked).count == 1)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["FEAT-1", "FEAT-2"])
        #expect(await world.local.revParse("refs/yellowhammer/landed/yh-f2") == landedSecond.tip)

        // F1 is merged with a merge commit; the next author firing records F1's Observed Merge.
        let merged = try await world.mergeIntoMainline("yh-f1")
        try journal.releaseActLease(runID: world.env.runID)
        let authorRun = RunID()
        _ = try journal.claimActLease(act: .author, runID: authorRun, mode: .real)
        let gateContext = world.context(act: .author, runID: authorRun, mainlineCommit: merged)
        let outcome = try await PredecessorAncestryGate().check(gateContext, unmergedFeaturesMax: 3)

        #expect(outcome == .open)
        #expect(try journal.landings(featureID: first)["repo-a"] != nil)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["FEAT-2"])
        #expect(await world.local.revParse("refs/yellowhammer/landed/yh-f1") == nil)
        #expect(await world.local.revParse("refs/yellowhammer/landed/yh-f2") == landedSecond.tip)

        // F3 is selected against F2's pinned tip, so its pull request targets b2.
        try journal.releaseActLease(runID: authorRun)
        try claimLandLease(journal, runID: world.env.runID)
        let bases = try await AuthoringBases.fromStack(context: gateContext)
        #expect(bases.records.first?.baseRef == "refs/yellowhammer/landed/yh-f2")
        #expect(bases.records.first?.stackedOnFeatureID == second)
        _ = try world.seedFeature(issueID: "FEAT-3", branch: "yh-f3", bases: bases.records)
        let landedThird = try await world.buildAndLand(branch: "yh-f3", from: landedSecond.tip, number: 9)

        #expect(landedThird.drafts.map(\.base) == ["yh-f2"])
        #expect(landedThird.drafts.first?.body.contains("Stacked on #8") == true)
    }
}
