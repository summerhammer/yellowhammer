import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// board-projection / operator-done (ruling OQ199), issue #736 AC1: a Work Card the Operator moved to Done in
// the same read as its Feature is Done, not auto-Blocked `feature completed` by the settle, and nothing is
// written to its issue.

@Suite("Author Act settle leaves a Card the Operator moved to Done alone (#736)")
struct FeatureSettleOperatorDoneTests {
    @Test("Card and Feature Done in one read: the Card is Done, never Blocked, detached or carried forward")
    func cardDoneWithItsFeatureIsNotBlocked() async throws {
        let world = try await makeSettleWorld(landed: false)
        let active = try await world.seedActiveCards()
        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let done = BoardWorkflowState(id: try scope.id(for: .done), name: "Done", category: .completed)
        _ = try await world.boards.writing.updateIssue(
            BoardObjectID(rawValue: "FEAT-1"), BoardIssueChange(workflowState: done.id)
        )
        let reading = FakeReadingBoard([
            page(objects: [
                object("BACK-3", state: done, updatedAt: 5),
                object("FEAT-1", state: done, updatedAt: 5)
            ]),
            page()
        ])
        try await reading.readThrough(world.boards)
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)
        let baseline = await world.boards.writing.writeLog.count

        try await EngineInvocation(
            act: .author, mode: .real, nightStart: settleObservingNightStart, journal: world.journal,
            trigger: .scheduled, runID: RunID(),
            board: ActBoard(reading: reading, writing: world.boards.writing, provisioning: world.boards.provisioning),
            repositories: nil, workspace: world.workspace,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(), authoring: authoring, settle: FeatureSettleGesture(),
                unmergedFeaturesMax: 3
            ).work
        ).run()

        let card = try world.journal.card(id: active.todo)
        #expect(card.state == .done)
        #expect(card.blockReason == nil)
        #expect(try world.journal.isOperatorDone(cardID: card.id))
        #expect(try world.journal.events(ofType: .cardRestated).isEmpty)
        #expect(await world.boards.writing.writes(to: BoardObjectID(rawValue: "BACK-3"), since: baseline).isEmpty)

        let completed = try world.journal.events(ofType: .featureCompleted)
        guard case .featureCompleted(_, _, let carried, let accepted, _)? = completed.first?.event else {
            Issue.record("expected featureCompleted")
            return
        }
        #expect(!carried.contains("BACK-3"))
        #expect(accepted.contains("BACK-3"))
        let leftBlocked = try world.journal.blockedCardsLeftByClosedFeatures().map(\.issueID)
        #expect(!leftBlocked.contains("BACK-3"))
        let unadopted = try world.journal.unadoptedCards(asOf: settleObservingNightStart).map(\.card.issueID)
        #expect(!unadopted.contains("BACK-3"))
    }
}
