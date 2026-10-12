import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature, OQ164: the land Act records the commit it pushed per (Feature,
// repository) in the Journal and pins it at refs/yellowhammer/landed/<branch> in the main clone. A pin that
// cannot be written is reported in the Journal only.

@Suite("Land Act push: landed tip")
struct LandActPushLandedTipTests {
    /// A local clone with a Feature Branch one commit ahead of `main`, and a bare remote to push to.
    private struct PushWorld {
        let local: TestGitRepo
        let remote: TestGitRepo
        let featureSHA: String
        let env: Environment
        let feature: FeatureRecord
        let cycleID: Int64
        let branch: FeatureBranch
    }

    private func makePushWorld(name: String, branch: FeatureBranch) async throws -> PushWorld {
        let local = TestGitRepo(name: "\(name)-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", branch.name])
        let featureSHA = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")
        let remote = TestGitRepo(name: "\(name)-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "BACK-1", description: nil)
        let (feature, cycleID) = try env.setUpFeature(branch: branch)
        return PushWorld(
            local: local, remote: remote, featureSHA: featureSHA, env: env, feature: feature, cycleID: cycleID,
            branch: branch
        )
    }

    private func runLane(_ world: PushWorld) async throws -> String? {
        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        return await land.run(
            lane: RepoLane(repository: "backend", cards: try world.env.journal.cards(cycleID: world.cycleID)),
            feature: world.feature, cycleID: world.cycleID, context: world.env.context
        )
    }

    @Test("a pushed lane records the pushed commit and pins it in the main clone, with a prefixed branch name")
    func pushedLaneRecordsAndPins() async throws {
        let branch = FeatureBranch(rawValue: "rozd/yh-proj-feat")
        let world = try await makePushWorld(name: "landed-tip-ok", branch: branch)

        #expect(try await runLane(world) == nil)

        let journal = world.env.journal
        #expect(try journal.landedCommit(featureID: world.feature.id, repository: "backend") == world.featureSHA)
        await #expect(world.local.revParse("refs/yellowhammer/landed/rozd/yh-proj-feat") == world.featureSHA)
        #expect(try world.env.journal.events(ofType: .landedPinFailed).isEmpty)

        // The pin outlives the branch refs.
        _ = await world.local.run(["checkout", "main"])
        _ = await world.local.run(["branch", "-D", branch.name])
        await #expect(world.local.revParse("refs/heads/\(branch.name)") == nil)
        await #expect(world.local.revParse("refs/yellowhammer/landed/rozd/yh-proj-feat") == world.featureSHA)
    }

    @Test("a pin that cannot be written leaves the push counted and the commit recorded, and is Journal-only")
    func failedPinIsJournalOnly() async throws {
        let world = try await makePushWorld(name: "landed-tip-pin-fails", branch: landBranch)
        // `refs/yellowhammer/landed` as a ref blocks `refs/yellowhammer/landed/<branch>` (a directory/file
        // conflict): the push succeeds and only the pin write fails.
        _ = await world.local.run(["update-ref", "refs/yellowhammer/landed", world.featureSHA])

        #expect(try await runLane(world) == nil)

        let step = try #require(world.env.pushStep(repository: "backend"))
        #expect(step.outcome == .completed)
        #expect(step.detail == world.featureSHA)
        await #expect(world.remote.revParse("refs/heads/\(landBranch.name)") == world.featureSHA)
        let journal = world.env.journal
        #expect(try journal.landedCommit(featureID: world.feature.id, repository: "backend") == world.featureSHA)

        let failures = try world.env.journal.events(ofType: .landedPinFailed)
        #expect(failures.count == 1)
        guard case .landedPinFailed(let issueID, let repository, let branch, let commit, let operation, let reason) =
            failures[0].event
        else {
            Issue.record("expected landedPinFailed")
            return
        }
        #expect(issueID == "FEAT-1")
        #expect(repository == "backend")
        #expect(branch == landBranch.name)
        #expect(commit == world.featureSHA)
        #expect(operation == .pin)
        #expect(!reason.isEmpty)

        // Journal-only: no Exception line, no anomaly, no Night Card line.
        let night = world.env.context.night
        #expect(try NightSummary.exceptionLines(night: night, journal: world.env.journal).isEmpty)
        #expect(try NightSummary.anomalyLines(night: night, journal: world.env.journal).isEmpty)
        #expect(NightCardMaintenance.authoringLine(for: failures[0].event, journal: world.env.journal) == nil)
    }

    @Test("a later push of the same Feature overwrites the recorded commit and moves the pin")
    func laterPushMovesTheRecordAndThePin() async throws {
        let world = try await makePushWorld(name: "landed-tip-repush", branch: landBranch)
        #expect(try await runLane(world) == nil)

        let second = try await world.local.commit(filename: "more.txt", content: "more", message: "more work")
        #expect(try await runLane(world) == nil)

        #expect(try world.env.journal.landedCommit(featureID: world.feature.id, repository: "backend") == second)
        await #expect(world.local.revParse("refs/yellowhammer/landed/\(landBranch.name)") == second)
    }

    @Test("a lane with no completed work records no commit and writes no pin")
    func noCompletedWorkRecordsNothing() async throws {
        let local = TestGitRepo(name: "landed-tip-none-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", landBranch.name])
        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        let (feature, cycleID) = try env.setUpFeature()
        try recordTouchedRepositories(env.journal, featureID: feature.id, repositories: ["backend"])

        let land = LandAct(push: FeatureBranchLanePush(credential: { nil }))
        let failure = await land.run(
            lane: RepoLane(repository: "backend", cards: try env.journal.cards(cycleID: cycleID)),
            feature: feature, cycleID: cycleID, context: env.context
        )

        #expect(failure == nil)
        #expect(try env.journal.landedCommit(featureID: feature.id, repository: "backend") == nil)
        await #expect(local.revParse("refs/yellowhammer/landed/\(landBranch.name)") == nil)
    }
}
