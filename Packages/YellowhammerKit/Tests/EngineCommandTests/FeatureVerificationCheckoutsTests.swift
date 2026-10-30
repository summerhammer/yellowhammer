import Domain
@testable import Engine
import Foundation
@testable import Journal
import Synchronization
import Testing

// OQ191 (yellowhammer#708): Verification resolves the judged commits every time, but makes the verifier's
// checkouts only when a clause goes to the verifier. Only wiring is asserted; no verdict a model would reach.

/// Records how many times Verification asked for checkouts to be made and removed; resolves a fixed plan.
private final class RecordingCheckouts: VerifierCheckoutPreparing, Sendable {
    private let counts = Mutex((planned: 0, materialised: 0, released: 0))
    let judged = JudgedCheckout(repository: "backend", commit: "abc1234", kind: .freshCheckout, noPushedBranch: false)

    var planned: Int { counts.withLock { $0.planned } }
    var materialised: Int { counts.withLock { $0.materialised } }
    var released: Int { counts.withLock { $0.released } }

    func plan(_ context: LandActFeatureContext, repositories: [String]) async throws -> VerifierCheckoutPlan {
        counts.withLock { $0.planned += 1 }
        return VerifierCheckoutPlan(repositories: repositories, judgedCheckouts: [judged])
    }

    func materialise(_ plan: VerifierCheckoutPlan, context: LandActFeatureContext) async throws -> VerifierCheckouts {
        counts.withLock { $0.materialised += 1 }
        return try await UnrecordedCheckouts().materialise(plan, context: context)
    }

    func release(_ checkouts: VerifierCheckouts) {
        counts.withLock { $0.released += 1 }
    }
}

@Suite("Verification makes checkouts only for clauses it dispatches", .tags(.oq191))
struct FeatureVerificationCheckoutsTests {
    private func verification(
        _ checkouts: RecordingCheckouts, dispatch: ScriptedVerifierDispatch
    ) -> FeatureVerification {
        FeatureVerification(
            resolver: verificationResolver(primary: routeOther), dispatch: dispatch,
            citations: FakeCitationResolver(), checkouts: checkouts
        )
    }

    @Test("When the engine decides every clause, no checkout is made, and the judged commit is still recorded")
    func engineDecidedClausesMakeNoCheckout() async throws {
        let world = try await VerificationWorld(cards: [VerificationCard("BACK-1", "backend", .blocked)])
        try world.addClause(issue: "BACK-1", cid: "c1")
        let checkouts = RecordingCheckouts()
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await verification(checkouts, dispatch: dispatch).verify(world.featureContext)

        #expect(dispatch.requests.isEmpty)
        #expect(checkouts.planned == 1)
        #expect(checkouts.materialised == 0)
        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        #expect(recorded.judgedCheckouts == [checkouts.judged])
    }

    @Test("When a clause goes to the verifier, the checkouts are made once and released")
    func dispatchedClausesMakeCheckouts() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let checkouts = RecordingCheckouts()
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await verification(checkouts, dispatch: dispatch).verify(world.featureContext)

        #expect(dispatch.requests.count == 1)
        #expect(checkouts.materialised == 1)
        #expect(checkouts.released == 1)
    }
}
