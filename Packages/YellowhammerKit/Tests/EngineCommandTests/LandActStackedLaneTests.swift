import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P23.4 (spec: landing/open-one-pull-request-per-repository, `hasNetChange` and the lane merge test;
// agent rulings 2026-10-21 items 6 and 11, pending sponsor review): completed work is detected against the
// Feature's recorded base, while the merge test stays against mainline. Real git; GitHub is never called.

@Suite("Land Act: a stacked lane's push and merge test (P23.4)")
struct LandActStackedLaneTests {
    private func pushedOutcomes(_ journal: JournalStore) throws -> [String] {
        try journal.events(ofType: .noPushedBranchOutcome).compactMap {
            if case .noPushedBranchOutcome(_, _, let repository) = $0.event { return repository }
            return nil
        }
    }

    private func addBareRemote(_ world: StackedLandWorld, name: String) async -> TestGitRepo {
        let remote = TestGitRepo(name: "\(name)-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await world.local.run(["remote", "set-url", "origin", remote.path])
        return remote
    }

    @Test("A stacked lane with one commit on the predecessor's tip is pushed")
    func stackedLaneWithOwnCommitIsPushed() async throws {
        let world = try await StackedLandWorld.make(name: "stacked-push-own")
        let remote = await addBareRemote(world, name: "stacked-push-own")
        let ownCommit = try await world.local.commit(filename: "f2.txt", content: "F2", message: "F2")

        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        let failure = await land.run(
            lane: try world.lane, feature: world.feature, cycleID: world.cycleID, context: world.env.context
        )

        #expect(failure == nil)
        #expect(world.env.pushStep(repository: "backend")?.outcome == .completed)
        await #expect(remote.revParse("refs/heads/\(landBranch.name)") == ownCommit)
        #expect(try pushedOutcomes(world.journal).isEmpty)
    }

    @Test("A stacked lane at the predecessor's tip with no commit of its own records No-Pushed-Branch, no PR")
    func stackedLaneAtPredecessorTipHasNoCompletedWork() async throws {
        let world = try await StackedLandWorld.make(name: "stacked-push-none")
        let remote = await addBareRemote(world, name: "stacked-push-none")
        // Against mainline the branch is one commit (F1's) ahead, so a recomputed base would push it.
        let ahead = await world.local.run(["rev-list", "--count", "\(world.mainline)..\(landBranch.name)"])
        #expect(ahead.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")

        let stub = StubPublicationAdapter(result: .success(.opened(url: "https://github.com/o/backend/pull/9")))
        let land = LandAct(
            push: FeatureBranchLanePush(credential: { nil }),
            openPullRequest: FeatureBranchPullRequest(
                publication: stub, clock: { landEpoch }, remoteTip: .at("deadbeef")
            )
        )
        let failure = await land.run(
            lane: try world.lane, feature: world.feature, cycleID: world.cycleID, context: world.env.context
        )

        #expect(failure == nil)
        #expect(try pushedOutcomes(world.journal) == ["backend"])
        await #expect(remote.revParse("refs/heads/\(landBranch.name)") == nil)
        #expect(await stub.calls.isEmpty)
        #expect(try world.journal.pullRequest(featureID: world.feature.id, repository: "backend") == nil)
    }

    /// An unstacked Feature with a recorded mainline base `M0`: its lane's own commit `L` sits on `M0`, and
    /// mainline has since moved forward to include `L`. Counted against the recorded base the lane has work
    /// (`M0..L` = 1); counted against today's mainline it would have none. Without a record the lane is never counted
    /// against mainline: the branch is treated as having work and pushed, because landing must never drop commits.
    @Test("An unstacked lane counts commits against its recorded mainline base, not mainline as it stands",
          arguments: [true, false])
    func unstackedLaneUsesRecordedMainlineBase(recorded: Bool) async throws {
        let local = TestGitRepo(name: "unstacked-recorded-\(recorded)-local")
        await local.initRepo(defaultBranch: "main")
        let base = try await local.commit(message: "mainline at selection")
        await local.run(["checkout", "-b", landBranch.name])
        let ownCommit = try await local.commit(filename: "lane.txt", content: "lane", message: "lane work")
        // Mainline moves forward after selection, to a commit that already contains the lane's.
        await local.run(["update-ref", "refs/heads/main", ownCommit])
        await local.run(["update-ref", "refs/remotes/origin/main", ownCommit])
        let remote = TestGitRepo(name: "unstacked-recorded-\(recorded)-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        let (feature, cycleID) = try env.setUpFeature()
        try recordTouchedRepositories(env.journal, featureID: feature.id, repositories: ["backend"])
        if recorded {
            try env.journal.recordFeatureBases(featureID: feature.id, bases: [
                FeatureBaseRecord(repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: base)
            ])
        }

        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )

        #expect(failure == nil)
        if recorded {
            await #expect(remote.revParse("refs/heads/\(landBranch.name)") == ownCommit)
            #expect(try pushedOutcomes(env.journal).isEmpty)
        } else {
            await #expect(remote.revParse("refs/heads/\(landBranch.name)") == ownCommit)
            #expect(try pushedOutcomes(env.journal).isEmpty)
        }
    }

    @Test("A stacked lane is still merge-tested against refs/remotes/origin/<default>, and inherits its conflict")
    func stackedLaneMergeTestsAgainstMainline() async throws {
        let world = try await StackedLandWorld.make(name: "stacked-merge", predecessorEdits: "shared.txt")
        _ = try await world.local.commit(filename: "f2.txt", content: "F2", message: "F2")
        // Mainline edits the line F1 changed: F1 conflicts, and so does F2, stacked on it.
        await world.local.run(["checkout", "main"])
        let mainline = try await world.local.commit(filename: "shared.txt", content: "main", message: "main edit")
        await world.local.run(["update-ref", "refs/remotes/origin/main", mainline])
        await world.local.run(["checkout", landBranch.name])

        let context = ActContext(
            act: .land, mode: .real, trigger: .scheduled, runID: world.env.runID, journal: world.journal,
            night: world.env.context.night, outbox: world.env.context.outbox,
            mainlines: ResolvedMainlines(workingRepos: [
                "backend": ResolvedMainline(
                    repository: "backend", defaultBranch: "main", ref: "refs/remotes/origin/main", commit: mainline
                )
            ]),
            workspace: nil, repositories: world.env.context.repositories
        )
        let outcome = try await FeatureBranchLaneMergeTest().test(try world.laneContext(act: context))

        #expect(outcome.mainlineRef == "refs/remotes/origin/main")
        #expect(outcome.mainlineCommit == mainline)
        #expect(!outcome.untestable)
        #expect(outcome.conflict)
        #expect(outcome.paths == ["shared.txt"])
    }
}
