import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// Operator Done on the Feature Managed Block (spec: board-projection/operator-done): the member row of a
// Card whose latest move into Done is the Journal's `.cardOperatorDone` event reads "done by the Operator".
// `OutboxJournalFixture` is created inside every @Test, never in a helper.

@Suite("Feature Roll-up maintenance: Operator Done")
struct RollUpOperatorDoneTests {
    @Test("A member the Operator moved to Done shows the marker in the posted block")
    func operatorDoneMemberShowsMarker() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        let cardID = try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .todo)
        )
        _ = try journal.markCardOperatorDone(
            cardID: cardID, runID: world.runID, act: .build, nightID: world.night.id
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))

        _ = try await FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)
            .maintain(feature: feature, cycleID: cycleID)

        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(description.contains("- `BACK-1` — Done · done by the Operator"))
    }

    @Test("A Card the Operator marked Done, moved out and back by Yellowhammer, shows no marker")
    func laterYellowhammerDoneShowsNoMarker() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try makeRollUpWorld(journal)
        await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        let cardID = try insertRollUpCard(
            journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .todo)
        )
        _ = try journal.markCardOperatorDone(
            cardID: cardID, runID: world.runID, act: .build, nightID: world.night.id
        )
        _ = try journal.transitionCard(
            cardID: cardID, to: .todo, runID: world.runID, act: .build, nightID: world.night.id
        )
        _ = try journal.transitionCard(
            cardID: cardID, to: .done, runID: world.runID, act: .build, nightID: world.night.id
        )
        let feature = try #require(try journal.feature(issueID: "FEAT-1"))

        _ = try await FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)
            .maintain(feature: feature, cycleID: cycleID)

        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(description.contains("- `BACK-1` — Done"))
        #expect(!description.contains("done by the Operator"))
    }
}
