import Domain
@testable import Engine
import Journal
import Testing

@Test("All Done with unmet clauses renders waiting and preserves the merged fraction")
func allDoneWithUnmetClauses() {
    let rollUp = FeatureRollUp(
        members: [RollUpMember(issueID: "A", repository: "backend", authoredOrder: 0, state: .done)],
        lanesPushed: true, verificationPassed: false, unmetClauseCount: 2,
        mergedFraction: MergedFraction(mergedCount: 1, totalCount: 2), issueStanding: .authoring
    )
    #expect(rollUp.state == .waiting)
    #expect(rollUp.sentence == "waiting · 1 of 1 Cards landed · 1 of 2 merged · 2 clauses unmet")
}

@Test("Managed Block counts both unmet and unresolved clauses from the Journal")
func managedBlockUnmetClauses() async throws {
    let fixture = try OutboxJournalFixture()
    let journal = try fixture.open()
    let world = try makeRollUpWorld(journal)
    await world.board.seed(issue: "FEAT-1", description: ManagedBlockFence.initialDescription(rendered: ""))
    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-1", branch: "yh-proj-feat", repositories: ["backend"]
    )
    let cycleID = try gateCycleID(journal, featureID: featureID)
    try insertRollUpCard(
        journal, cycleID: cycleID, .init(issueID: "BACK-1", repository: "backend", order: 1, state: .done)
    )
    try journal.markCycleLanded(cycleID: cycleID, runID: world.runID)
    let clauses = [ClauseVerdict.met, .unmet, .unresolved].enumerated().map { index, verdict in
        ClauseVerificationRecord(
            issueID: "BACK-1", cid: "c\(index)", level: "card", text: "Fixture clause \(index)",
            locationID: "fixture#clause-\(index)", citationProvenance: "machine-found", verdict: verdict,
            whatWasChecked: "Fixture", interpretation: "Fixture", judgedBy: .engine
        )
    }
    try journal.recordFeatureVerification(NewFeatureVerification(
        featureID: featureID, cycleID: cycleID, route: nil, nightID: world.night.id,
        runID: world.runID, clauses: clauses
    ))
    let feature = try #require(try journal.feature(issueID: "FEAT-1"))
    _ = try await FeatureRollUpMaintenance(journal: journal, outbox: world.outbox)
        .maintain(feature: feature, cycleID: cycleID)
    let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
    #expect(description.contains("waiting · 1 of 1 Cards landed · 0 of 1 merged · 2 clauses unmet"))
}
