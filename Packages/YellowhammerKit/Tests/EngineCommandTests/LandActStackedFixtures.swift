import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P23.4: the shared world of the stacked-landing tests. F1 (`FEAT-0`, displayed `YLH-1`) is archived,
// verified and in the Unmerged Feature Stack U, having pushed `b1` in `backend` at `C1`, pinned at
// `refs/yellowhammer/landed/b1`. F2 (`FEAT-1`) is in flight, its `backend` Feature Branch (`yh-proj-feat`) cut
// from `C1`, with `feature_base` recording `refs/yellowhammer/landed/b1` at `C1`.

/// A local clone with mainline `M`, F1's branch `b1` one commit ahead at `C1`, and F2's branch cut from `C1`.
struct StackedLandWorld {
    let local: TestGitRepo
    let mainline: String
    let predecessorTip: String
    let env: Environment
    let predecessorID: Int64
    let feature: FeatureRecord
    let cycleID: Int64

    /// Builds the world. `predecessorEdits` is the file F1's commit changes (so a test can make mainline
    /// conflict with it); `remote` is the origin URL; `partial` seeds F2 as a Partial Landing.
    static func make(
        name: String, remote: String = "git@github.com:summerhammer/backend.git",
        predecessorEdits: String = "f1.txt", partial: Bool = false
    ) async throws -> StackedLandWorld {
        let local = TestGitRepo(name: "\(name)-local")
        await local.initRepo(defaultBranch: "main")
        let mainline = try await local.commit(filename: predecessorEdits, content: "base", message: "mainline")
        await local.run(["update-ref", "refs/remotes/origin/main", mainline])
        await local.run(["checkout", "-b", "b1"])
        let tip = try await local.commit(filename: predecessorEdits, content: "F1", message: "F1")
        await local.run(["update-ref", "refs/yellowhammer/landed/b1", tip])
        await local.run(["checkout", "-b", landBranch.name])
        await local.addRemote(url: remote)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: "x"))
        await env.board.seed(issue: "BACK-1", description: nil)
        let predecessorID = try insertGateFeature(
            env.journal, issueID: "FEAT-0", branch: "b1", repositories: ["backend"], landed: true,
            pushedTips: ["backend": tip]
        )
        try env.journal.write { db in
            try db.execute(sql: "UPDATE feature SET issue_key = 'YLH-1' WHERE id = ?", arguments: [predecessorID])
        }
        let (feature, cycleID): (FeatureRecord, Int64)
        if partial {
            let partialCycleID = try FeatureBranchPullRequestTests.setUpPartialLandingFixture(env.journal)
            feature = try #require(try env.journal.inFlightFeature()).feature
            cycleID = partialCycleID
        } else {
            (feature, cycleID) = try env.setUpFeature()
        }
        try recordTouchedRepositories(env.journal, featureID: feature.id, repositories: ["backend"])
        try env.journal.recordFeatureBases(featureID: feature.id, bases: [
            FeatureBaseRecord(
                repository: "backend", baseRef: "refs/yellowhammer/landed/b1", baseCommit: tip,
                stackedOnFeatureID: predecessorID
            )
        ])
        return StackedLandWorld(
            local: local, mainline: mainline, predecessorTip: tip, env: env, predecessorID: predecessorID,
            feature: feature, cycleID: cycleID
        )
    }

    var journal: JournalStore { env.journal }

    var lane: RepoLane {
        get throws { RepoLane(repository: "backend", cards: try journal.cards(cycleID: cycleID)) }
    }

    func laneContext(act: ActContext? = nil) throws -> LandActLaneContext {
        LandActLaneContext(act: act ?? env.context, feature: feature, cycleID: cycleID, lane: try lane)
    }

    /// Records F1's pull request in `backend`, as its own landing did.
    func recordPredecessorPullRequest(url: String = "https://github.com/summerhammer/backend/pull/7") throws {
        try journal.recordPullRequest(
            featureID: predecessorID, repository: "backend", url: url, nightID: env.context.night.id,
            runID: env.runID, now: landEpoch
        )
    }
}
