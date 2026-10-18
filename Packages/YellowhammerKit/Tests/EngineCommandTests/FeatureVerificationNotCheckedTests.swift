import Domain
@testable import Engine
import Journal
import Testing

// Fixed verifier answers exercise persistence and routing, not the correctness of a model's verdict.
@Suite("Verification: checks that never ran")
struct FeatureVerificationNotCheckedTests {
    @Test("A not checked answer is recorded without falling back, and reused on retry")
    func notCheckedIsAClauseVerdict() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let answer = VerifierResult(outcome: .reported(clauses: [
            VerifiedClause(
                cid: "c1", issueID: "BACK-1", verdict: .notChecked,
                whatWasChecked: "The check could not run: network access is unavailable.",
                interpretation: "The endpoint must respond to a live request."
            )
        ]))
        let dispatch = ScriptedVerifierDispatch([
            routeOther: .answer(.verifier(answer)), routeThird: .judgeAll()
        ])
        let verification = world.verification(
            resolver: verificationResolver(primary: routeOther, fallbacks: [routeThird]), dispatch: dispatch
        )

        let first = try await verification.verify(world.featureContext)
        let retried = try await verification.verify(world.featureContext)

        #expect(dispatch.requests.map(\.route) == [routeOther])
        #expect(!first.allClausesMet)
        #expect(first.unmetClauses.isEmpty)
        #expect(first.unresolvedClauses.isEmpty)
        #expect(first.notCheckedClauses == ["BACK-1 c1"])
        #expect(retried == first)
        #expect(try world.journal.events(ofType: .authoringRouteRejected).isEmpty)
        #expect(try world.journal.events(ofType: .featureVerified).map(\.event) == [
            .featureVerified(cycleID: world.cycleID, met: 0, unmet: 0, unresolved: 0, notChecked: 1)
        ])
        let record = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        let clause = try #require(record.clauses.first)
        #expect(clause.verdict == .notChecked)
        #expect(clause.whatWasChecked == "The check could not run: network access is unavailable.")
    }
}
