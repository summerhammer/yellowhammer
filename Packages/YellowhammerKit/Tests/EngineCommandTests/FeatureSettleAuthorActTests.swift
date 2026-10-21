import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P22.2 (spec: morning-report/triage-the-morning): the author Act applies the Feature Card's
// native disposition after merge evidence, then re-reads the predecessor gate in the same Act. Never
// asserts anything model-authored.

@Suite("Author Act applies the native disposition (P22.2)")
struct FeatureSettleAuthorActTests {
    @Test("Done after every pushed repository merged: the same Act selects the next Feature")
    func doneAfterAllMergedSelectsInTheSameAct() async throws {
        let world = try await makeSettleWorld(landed: true)
        try resolveWaiting(world)
        try recordLandings(world, repositories: ["backend", "mobile"])
        try await completeOnTheBoard(world)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await authorAct(
            world, authoring: authoring, gate: PredecessorAncestryGate(), reading: try await linkedReading(world)
        ).run()

        #expect(authoring.wasCalled)
        let types = try world.journal.events().map(\.type)
        #expect(types.contains(.featureCompleted))
        #expect(!types.contains(.authoringSkippedFeatureInFlight))
        #expect(!types.contains(.authoringSkippedUnmergedStackFull))
        #expect(!types.contains(.authoringPredecessorIndeterminate))
        #expect(try settleFeatureRow(world.journal, featureID: world.featureID).closedBy == "completion")
        #expect(try world.journal.inFlightFeature() == nil)
    }

    @Test("Merge wins over a same-morning Done: the closure by merge runs first and the Act still selects")
    func mergeClosureRunsBeforeTheDisposition() async throws {
        let world = try await makeSettleWorld(landed: true)
        try resolveWaiting(world)
        try recordLandings(world, repositories: ["backend", "mobile"])
        try await completeOnTheBoard(world)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await authorAct(
            world, authoring: authoring, gate: PredecessorAncestryGate(closure: FeatureMergeClosure()),
            reading: try await linkedReading(world)
        ).run()

        #expect(authoring.wasCalled)
        #expect(try settleFeatureRow(world.journal, featureID: world.featureID).closedBy == "merge")
        #expect(try world.journal.events(ofType: .featureCompleted).isEmpty)
    }

    // At unmerged_features_max = 1 the completed Feature, entering the Unmerged Feature Stack, closes the gate.
    @Test("Done with a pushed repository unmerged, max 1: the slot is free, selection blocked, the repository named")
    func doneWithAnUnmergedRepositoryNamesTheBlocker() async throws {
        let backend = GateGitFixture(name: "settle-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", settleFeatureBranch])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge", settleFeatureBranch])

        let mobile = GateGitFixture(name: "settle-mobile")
        await mobile.initRepo()
        _ = try await mobile.commit(message: "init")
        _ = await mobile.run(["checkout", "-b", settleFeatureBranch])
        _ = try await mobile.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await mobile.run(["checkout", "main"])

        let world = try await makeSettleWorld(landed: true)
        try resolveWaiting(world)
        try await completeOnTheBoard(world)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)
        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ])

        try await authorAct(
            world, authoring: authoring, gate: PredecessorAncestryGate(), reading: try await linkedReading(world),
            repositories: repositories, unmergedFeaturesMax: 1
        ).run()

        #expect(!authoring.wasCalled)
        // The slot is free: the Feature left flight as completed, and the Act did not skip as "in flight".
        #expect(try world.journal.inFlightFeature() == nil)
        let types = try world.journal.events().map(\.type)
        #expect(!types.contains(.authoringSkippedFeatureInFlight))
        let blocked = try world.journal.events(ofType: .authoringSkippedUnmergedStackFull)
        guard case .authoringSkippedUnmergedStackFull(let features, 1)? = blocked.first?.event else {
            Issue.record("expected authoringSkippedUnmergedStackFull at max 1")
            return
        }
        #expect(features.map(\.featureIssueID) == ["FEAT-1"])
        #expect(features.first?.unmergedRepositories == ["mobile"])
        let blockedEvent = try #require(blocked.first).event
        let line = try #require(NightCardMaintenance.authoringLine(for: blockedEvent, journal: world.journal))
        #expect(line.contains("mobile"))
        #expect(line.contains("completed on the Board"))
        #expect(!line.localizedCaseInsensitiveContains("unsettled"))
    }

    @Test("Done with N = 0 frees the slot with no merge gate and no merge claim")
    func doneWithNothingPushedFreesTheSlot() async throws {
        let world = try await makeSettleWorld(landed: false)
        try await world.seedFeatureDone()
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await authorAct(
            world, authoring: authoring, gate: PredecessorAncestryGate(), reading: world.reading
        ).run()

        #expect(authoring.wasCalled)
        let types = try world.journal.events().map(\.type)
        #expect(types.contains(.featureCompleted))
        #expect(!types.contains(.authoringSkippedUnmergedStackFull))
        #expect(!types.contains(.authoringPredecessorIndeterminate))
        #expect(!types.contains(.predecessorAncestryObserved))
        #expect(!types.contains(.featureClosedByMerge))
        #expect(!types.contains(.verifiedFeatureMergeObserved))
        #expect(try world.journal.landings(featureID: world.featureID).isEmpty)
        let comment = try #require(await world.boards.writing.comments.first { $0.issue.rawValue == "FEAT-1" })
        #expect(!comment.body.localizedCaseInsensitiveContains("merged"))
    }

    @Test("Cancelled: the Feature is abandoned and the walk skips it, so the same Act selects")
    func cancelledIsSkippedAndTheActSelects() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureCancelled()
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await authorAct(
            world, authoring: authoring, gate: PredecessorAncestryGate(), reading: world.reading
        ).run()

        #expect(authoring.wasCalled)
        let types = try world.journal.events().map(\.type)
        #expect(types.contains(.featureReleased))
        #expect(!types.contains(.featureCompleted))
        #expect(try settleFeatureRow(world.journal, featureID: world.featureID).abandonedAt != nil)
    }

    @Test("A started state never resets and posts nothing: the Feature keeps the slot across Nights")
    func startedStateKeepsTheSlotWithoutAReset() async throws {
        let world = try await makeSettleWorld()
        await world.seedFeatureIssueState("In Review", category: .started)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        for _ in 0..<2 {
            try await authorAct(
                world, authoring: authoring, gate: PredecessorAncestryGate(), reading: world.reading
            ).run()
        }

        #expect(!authoring.wasCalled)
        let types = try world.journal.events().map(\.type)
        #expect(types.contains(.authoringSkippedFeatureInFlight))
        #expect(!types.contains(.featureCompleted))
        #expect(!types.contains(.featureReleased))
        // Other Managed Block upkeep may comment on the issue; no settlement comment is ever posted for a started state.
        let featureComments = await world.boards.writing.comments.filter { $0.issue.rawValue == "FEAT-1" }
        #expect(featureComments.allSatisfy { !$0.body.contains(FeatureCompletionComment.headline) })
        #expect(featureComments.allSatisfy { !$0.body.hasPrefix("**Abandoned.**") })
        let featureIssue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1")))
        #expect(featureIssue.workflowState == nil, "nothing moved the Feature Card back to Todo")
    }

    // MARK: - Helpers

    private func authorAct(
        _ world: SettleWorld, authoring: ScriptedFeatureAuthoring, gate: PredecessorAncestryGate,
        reading: FakeReadingBoard, repositories: ProjectRepositories? = nil, unmergedFeaturesMax: Int = 3
    ) -> EngineInvocation {
        EngineInvocation(
            act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(),
            board: ActBoard(
                reading: reading, writing: world.boards.writing, provisioning: world.boards.provisioning
            ),
            repositories: repositories, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: gate, authoring: authoring, settle: FeatureSettleGesture(),
                unmergedFeaturesMax: unmergedFeaturesMax
            ).work
        )
    }

    /// A landed in-flight Cycle is read by the author Act first; the page is empty and reads through to
    /// the writing board, so the Feature Card's state is whatever the test left there.
    private func linkedReading(_ world: SettleWorld) async throws -> FakeReadingBoard {
        let reading = FakeReadingBoard([page(objects: [])])
        try await reading.readThrough(world.boards)
        return reading
    }

    private func recordLandings(_ world: SettleWorld, repositories: [String]) throws {
        for repository in repositories {
            try world.journal.recordLanding(
                featureID: world.featureID, repository: repository, mainlineCommit: "c-\(repository)",
                evidence: .ancestry
            )
        }
    }

    /// Takes the world's Waiting on You Card out of Waiting on You, so nothing is left to bank.
    private func resolveWaiting(_ world: SettleWorld) throws {
        try world.journal.write { db in
            try db.execute(
                sql: "UPDATE card SET state = ?, waiting_reason = NULL WHERE id = ?",
                arguments: [CardState.done.rawValue, world.waitingCardID]
            )
        }
    }

    /// Moves the Feature Card to the board's Done state on the writing board the reading board reads through.
    private func completeOnTheBoard(_ world: SettleWorld) async throws {
        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        _ = try await world.boards.writing.updateIssue(
            BoardObjectID(rawValue: "FEAT-1"), BoardIssueChange(workflowState: try scope.id(for: .done))
        )
    }
}
