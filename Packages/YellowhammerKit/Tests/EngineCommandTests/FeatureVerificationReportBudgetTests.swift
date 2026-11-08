import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// issue #670 (verification/verify-a-feature-clause-by-clause; board-projection/maintain-the-managed-block):
// the land-time report reaches the Feature Issue compacted when the full report is over the description
// budget, instead of being dropped. Board state, not outbox rows.

@Suite("Verification: the report fits the Feature Issue's description budget (#670)")
struct FeatureVerificationReportBudgetTests {
    @Test("An over-budget full report lands compacted on the Feature Issue's Managed Block")
    func compactedReportLands() async throws {
        let seed = "Operator prose.\n" + ManagedBlockFence.initialDescription(rendered: "roll-up")
        let budget = try DescriptionBudget(
            configured: 1_800, limit: BoardDescriptionLimit(maximum: 100_000, unit: .utf16CodeUnits)
        )
        let world = try await VerificationWorld(descriptionBudget: budget, featureDescription: seed)
        for cid in ["c1", "c2", "c3"] { try world.addClause(issue: "BACK-1", cid: cid) }
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let long = String(repeating: "looked at it carefully ", count: 60)
        let clauses = ["c1", "c2", "c3"].map {
            VerifiedClause(cid: $0, issueID: "BACK-1", verdict: .met, whatWasChecked: long, interpretation: long)
        }
        let answer = DispatchResult.verifier(VerifierResult(outcome: .reported(clauses: clauses)))
        let dispatch = ScriptedVerifierDispatch([routeOther: .answer(answer)])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)
        let outbox = try #require(world.featureContext.act.outbox)
        _ = try await outbox.deliverPending()
        _ = try await FeatureRollUpMaintenance(journal: world.journal, outbox: outbox)
            .maintain(feature: world.featureContext.feature, cycleID: world.cycleID)

        let description = try #require(await world.board.issue(BoardObjectID(rawValue: "FEAT-1"))?.description)
        #expect(description.hasPrefix("Operator prose.\n"))
        #expect(description.contains("### Cards"))
        #expect(description.utf16.count <= 1_800)
        #expect(description.contains("Compacted to fit the description budget"))
        for cid in ["c1", "c2", "c3"] { #expect(description.contains("Verification: BACK-1 \(cid) · ")) }
        #expect(!description.contains("looked at it carefully"))
        #expect(description.contains(VerificationReport.limitation))
        #expect(await world.board.comments.isEmpty)
    }
}
