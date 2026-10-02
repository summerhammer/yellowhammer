import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// risks OQ104, OQ107 (glossary: No-Pushed-Branch Outcome): every reader of N — the predecessor-ancestry
// gate, closure by merge, the Roll-up's merged fraction, the Night Summary's in-flight line — reads the
// repositories that pushed a Feature Branch, never one with the outcome. Pure local git over real
// fixture repositories, on top of ``MergeWorld`` (FeatureMergeClosureFixtures.swift).

/// Records the No-Pushed-Branch Outcome for `repository` and puts its fixture branch at its base, as a
/// lane that produced no completed work leaves it.
private func giveNoPushedBranchOutcome(_ world: MergeWorld, repository: String) async throws {
    try world.journal.append(
        .noPushedBranchOutcome(cycleID: world.cycleID, featureIssueID: "FEAT-1", repository: repository),
        act: .land, runID: RunID(), nightID: world.landingNightID
    )
    if repository == "backend" {
        _ = await world.backend.run(["branch", "-f", mergeClosureBranch, "main"])
    } else {
        _ = await world.mobile.run(["branch", "-f", mergeClosureBranch, "main"])
    }
}

/// A new Act context on the observing Night, after the previous one's lease is let go.
private func nextContext(
    _ world: MergeWorld, after previous: ActContext, repositories: ProjectRepositories
) throws -> ActContext {
    try? world.journal.releaseActLease(runID: previous.runID)
    return try world.makeContext(repositories: repositories)
}

private func observations(_ journal: JournalStore) throws -> [(merged: [String], unmerged: [String])] {
    try journal.events(ofType: .predecessorAncestryObserved).compactMap {
        if case .predecessorAncestryObserved(_, let merged, let unmerged) = $0.event { return (merged, unmerged) }
        return nil
    }
}

private func postRollUp(_ world: MergeWorld, context: ActContext) async throws -> String {
    await world.boards.writing.seed(
        issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: "")
    )
    let feature = try #require(try world.journal.feature(issueID: "FEAT-1"))
    let outbox = try #require(context.outbox)
    _ = try await FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
        .maintain(feature: feature, cycleID: world.cycleID)
    return try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
}

/// The Managed Block's first line (the bold Roll-up sentence with its notes beside it).
private func rollUpFirstLine(_ description: String) -> String? {
    try? ManagedBlockFence.parts(of: description).get().block.components(separatedBy: "\n").first
}

@Suite("No-Pushed-Branch Outcome: the gate, closure and N = 0 (OQ104, OQ107)")
struct NoPushedBranchGateTests {
    @Test("One empty lane: the gate reads only the pushed repository, and merging it closes the Feature")
    func oneEmptyLane() async throws {
        let world = try await makeMergeWorld(mergedRepositories: [])
        try await giveNoPushedBranchOutcome(world, repository: "mobile")
        let repositories = mergeWorldRepositories(world)
        let context = try world.makeContext(repositories: repositories)
        let gate = PredecessorAncestryGate(closure: FeatureMergeClosure())

        _ = try await gate.check(context)

        let first = try #require(try observations(world.journal).last)
        #expect(first.merged.isEmpty)
        #expect(first.unmerged == ["backend"])
        #expect(try world.journal.landings(featureID: world.featureID).isEmpty)
        #expect(try world.journal.inFlightFeature() != nil)
        #expect(try world.journal.touchedRepositories(featureID: world.featureID) == ["backend", "mobile"])

        let rollUpContext = try nextContext(world, after: context, repositories: repositories)
        let description = try await postRollUp(world, context: rollUpContext)
        #expect(description.contains("0 of 1 merged"))
        // P19.7 (risks OQ108): exactly one note, for the empty lane, beside the sentence on both surfaces.
        let noteFirstLine = try #require(rollUpFirstLine(description))
        #expect(noteFirstLine.hasSuffix("0 of 1 merged · 1 waiting on you** [no pull request: mobile]"))
        #expect(description.components(separatedBy: "[no pull request:").count == 2)
        let line = try #require(
            try NightSummary.inFlightFeatureLines(night: context.night, journal: world.journal).first
        )
        #expect(line.contains("0 of 1 Feature Branches merged"))
        #expect(line.hasSuffix(" [no pull request: mobile]"))
        #expect(line.components(separatedBy: "[no pull request:").count == 2)

        _ = await world.backend.run(["merge", "--no-ff", "-m", "merge", mergeClosureBranch])
        let next = try nextContext(world, after: rollUpContext, repositories: repositories)
        _ = try await gate.check(next)

        #expect(try world.journal.landings(featureID: world.featureID).keys.sorted() == ["backend"])
        let closures = try world.journal.events(ofType: .featureClosedByMerge)
        #expect(closures.count == 1)
        guard case .featureClosedByMerge(_, _, let merged, _, _, _) = try #require(closures.first).event else {
            Issue.record("expected featureClosedByMerge")
            return
        }
        #expect(merged == ["backend"])
        #expect(try world.journal.inFlightFeature() == nil)
    }

    @Test("Every lane empty: no pass, no landing, no closure; 0 of 0 everywhere; the Feature leaves by release")
    func everyLaneEmpty() async throws {
        let world = try await makeMergeWorld(mergedRepositories: [])
        try await giveNoPushedBranchOutcome(world, repository: "backend")
        try await giveNoPushedBranchOutcome(world, repository: "mobile")
        let repositories = mergeWorldRepositories(world)
        let gate = PredecessorAncestryGate(closure: FeatureMergeClosure())

        var context = try world.makeContext(repositories: repositories)
        for _ in 0..<2 {
            context = try nextContext(world, after: context, repositories: repositories)
            _ = try await gate.check(context)
            #expect(try observations(world.journal).isEmpty)
            #expect(try world.journal.landings(featureID: world.featureID).isEmpty)
            #expect(try world.journal.events(ofType: .featureClosedByMerge).isEmpty)
            #expect(try world.journal.inFlightFeature() != nil)
        }
        #expect(try world.journal.pushedRepositories(featureID: world.featureID).isEmpty)

        context = try nextContext(world, after: context, repositories: repositories)
        let description = try await postRollUp(world, context: context)
        #expect(description.contains("0 of 0 merged"))
        let noteFirstLine = try #require(rollUpFirstLine(description))
        #expect(noteFirstLine.hasSuffix(
            "0 of 0 merged · 1 waiting on you** [no pull request: backend] [no pull request: mobile]"
        ))
        let feature = try #require(try world.journal.feature(issueID: "FEAT-1"))
        let outbox = try #require(context.outbox)
        let again = try await FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
            .maintain(feature: feature, cycleID: world.cycleID)
        guard case .skipped = again else {
            Issue.record("expected a hash-skip, got \(again)")
            return
        }
        let line = try #require(
            try NightSummary.inFlightFeatureLines(night: context.night, journal: world.journal).first
        )
        #expect(line.contains("0 of 0 Feature Branches merged"))
        #expect(line.hasSuffix(" [no pull request: backend] [no pull request: mobile]"))

        try await release(world, after: context, repositories: repositories)
        #expect(try world.journal.inFlightFeature() == nil)
        #expect(try world.journal.events(ofType: .featureClosedByMerge).isEmpty)
    }

    /// The Feature leaves flight through the settle gesture's `released` value, as an Operator would.
    private func release(
        _ world: MergeWorld, after previous: ActContext, repositories: ProjectRepositories
    ) async throws {
        let base = try nextContext(world, after: previous, repositories: repositories)
        let reading = FakeReadingBoard([])
        await reading.seed(
            issue: BoardObject(
                id: BoardObjectID(rawValue: "FEAT-1"), key: "FEAT-1", title: "Feature", description: nil,
                workflowState: BoardWorkflowState(
                    id: BoardObjectID(rawValue: "state-released"), name: SettleValue.released.rawValue
                ),
                labels: [], parent: nil, url: "https://example.com/FEAT-1",
                createdAt: outboxEpoch, updatedAt: outboxEpoch
            )
        )
        let context = ActContext(
            act: base.act, mode: base.mode, trigger: base.trigger, runID: base.runID, journal: base.journal,
            night: base.night, outbox: base.outbox,
            board: ActBoard(reading: reading, writing: world.boards.writing, provisioning: world.boards.provisioning),
            repositories: repositories
        )
        let feature = try #require(try world.journal.feature(issueID: "FEAT-1"))
        try await FeatureSettleGesture().settle(feature: feature, cycleID: world.cycleID, context: context)
    }

    @Test("closeByMerge on a Feature whose N is empty writes nothing")
    func closeByMergeAtNZeroWritesNothing() async throws {
        let world = try await makeMergeWorld(mergedRepositories: [])
        try await giveNoPushedBranchOutcome(world, repository: "backend")
        try await giveNoPushedBranchOutcome(world, repository: "mobile")
        let context = try world.makeContext(repositories: mergeWorldRepositories(world))
        let feature = try #require(try world.journal.feature(issueID: "FEAT-1"))

        try await FeatureMergeClosure().closeByMerge(feature: feature, context: context)

        let events = try world.journal.events().map(\.type)
        #expect(!events.contains(.featureClosedByMerge))
        #expect(!events.contains(.cycleArchived))
        #expect(try world.journal.inFlightFeature() != nil)
        #expect(try world.journal.card(id: world.waitingCardID).state == .waitingOnYou)
        #expect(await world.boards.writing.archiveCalls == 0)
    }

    @Test("A walk predecessor with no touched repositories reads landed, with no pass and no closure")
    func walkPredecessorWithNoRepositories() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(journal, issueID: "FEAT-OLD", branch: "yh-proj-old", repositories: [])
        try journal.write { db in
            try db.execute(sql: "UPDATE cycle SET archived_at = ? WHERE feature_id = ?", arguments: [
                JournalStore.timestamp(outboxEpoch), featureID
            ])
        }
        let walk = try journal.predecessorFeature()
        #expect(walk.predecessor?.pushedRepositories == [])
        #expect(walk.predecessor?.touchedRepositories == [])
    }
}
