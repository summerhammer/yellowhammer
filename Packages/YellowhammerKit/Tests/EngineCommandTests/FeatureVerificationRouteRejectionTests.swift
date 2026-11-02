import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// The verifier's Route walk records one `AuthoringRouteRejected` event per Route it excludes, as an authoring
// walk does (spec: morning-report/disclose-a-failure#each-route). Wiring and recording only — never that a
// verdict a model reached is correct.

private struct RecordedRejection: Equatable {
    let pass: RunPass
    let route: String
    let ordinal: Int
    let cause: AuthoringRouteRejectionCause
}

private func rejections(_ world: VerificationWorld) throws -> [RecordedRejection] {
    try world.journal.events(ofType: .authoringRouteRejected).compactMap { record in
        guard case .authoringRouteRejected(let pass, let route, let ordinal, let cause, _) = record.event else {
            return nil
        }
        return RecordedRejection(pass: pass, route: route, ordinal: ordinal, cause: cause)
    }
}

@Suite("Verification: one event per rejected Route")
struct FeatureVerificationRouteRejectionTests {
    @Test("A refusal, a non-zero exit and a broken result contract are three rejections, in walk order")
    func threeRoutesThenExhaustion() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([
            routeWriter: .refuse, routeOther: .exit(2), routeThird: .contractViolation
        ])
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther, routeThird])

        await #expect(throws: VerificationDispatchFault.self) {
            try await world.verification(resolver: resolver, dispatch: dispatch).verify(world.featureContext)
        }

        #expect(
            try rejections(world) == [
                RecordedRejection(pass: .verifier, route: routeWriter.description, ordinal: 1, cause: .unavailable),
                RecordedRejection(pass: .verifier, route: routeOther.description, ordinal: 2, cause: .exited),
                RecordedRejection(
                    pass: .verifier, route: routeThird.description, ordinal: 3, cause: .brokeResultContract
                )
            ]
        )
    }

    @Test("A failed result and an incomplete one are rejections with their own causes")
    func reportedFailedAndInvalidOutput() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let failed = DispatchResult.verifier(VerifierResult(outcome: .failed(reason: "cannot read")))
        let empty = DispatchResult.verifier(VerifierResult(outcome: .reported(clauses: [])))
        let dispatch = ScriptedVerifierDispatch([
            routeWriter: .answer(failed), routeOther: .answer(empty), routeThird: .judgeAll()
        ])
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther, routeThird])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        #expect(try rejections(world).map(\.cause) == [.reportedFailed, .invalidOutput])
        let reasons = try world.journal.events(ofType: .authoringRouteRejected).compactMap { record -> String? in
            guard case .authoringRouteRejected(_, _, _, _, let reason) = record.event else { return nil }
            return reason
        }
        #expect(reasons.first == "cannot read")
    }

    @Test("A usage-limited Route is deferred, not rejected")
    func usageLimitRecordsNoRejection() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .usageLimit, routeThird: .judgeAll()])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        _ = try await world.verification(resolver: resolver, dispatch: dispatch).verify(world.featureContext)

        #expect(try rejections(world).isEmpty)
        #expect(try world.journal.events(ofType: .routeUsageLimited).count == 1)
    }

    @Test("A walk that fails on Route 1 and is answered by Route 2 records one rejection and returns the verdicts")
    func recoveredWalk() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .exit(1), routeThird: .judgeAll()])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        #expect(
            try rejections(world)
                == [RecordedRejection(pass: .verifier, route: routeOther.description, ordinal: 1, cause: .exited)]
        )
    }

    @Test("A Crashed-Unknown run still ends Verification with no rejection recorded")
    func crashRecordsNoRejection() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .crash, routeThird: .judgeAll()])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        await #expect(throws: VerificationDispatchFault.self) {
            try await world.verification(resolver: resolver, dispatch: dispatch).verify(world.featureContext)
        }

        #expect(try rejections(world).isEmpty)
    }

    // MARK: - Screening rejections (OQ157)

    @Test("Dropping a machine-found clause rejects the Route as invalid output (OQ157)")
    func droppedMachineFoundClauseRejected() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1", provenance: "machine-found")
        let droppedMachineFound = DispatchResult.verifier(VerifierResult(outcome: .reported(
            clauses: [],
            dropped: [DroppedVerificationClause(cid: "c1", issueID: "BACK-1", reason: "asserts landing's own output")]
        )))
        let dispatch = ScriptedVerifierDispatch([
            routeOther: .answer(droppedMachineFound), routeThird: .judgeAll()
        ])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        #expect(try rejections(world).map(\.cause) == [.invalidOutput])
        let reasons = try world.journal.events(ofType: .authoringRouteRejected).compactMap { record -> String? in
            guard case .authoringRouteRejected(_, _, _, _, let reason) = record.event else { return nil }
            return reason
        }
        #expect(reasons.first == "dropped a machine-found clause")
    }

    @Test("Leaving a dispatched clause uncovered rejects the Route as invalid output (OQ157)")
    func uncoveredClauseRejected() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "BACK-1", cid: "c2")
        let incomplete = DispatchResult.verifier(VerifierResult(outcome: .reported(
            clauses: [VerifiedClause(
                cid: "c1", issueID: "BACK-1", verdict: .met, whatWasChecked: "w", interpretation: "i"
            )],
            dropped: []
        )))
        let dispatch = ScriptedVerifierDispatch([
            routeOther: .answer(incomplete), routeThird: .judgeAll()
        ])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        #expect(try rejections(world).map(\.cause) == [.invalidOutput])
    }

    @Test("Naming a clause in both clauses and dropped rejects the Route as invalid output (OQ157)")
    func namedInBothListsRejected() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1", provenance: "Author-supplied")
        let both = DispatchResult.verifier(VerifierResult(outcome: .reported(
            clauses: [VerifiedClause(
                cid: "c1", issueID: "BACK-1", verdict: .met, whatWasChecked: "w", interpretation: "i"
            )],
            dropped: [DroppedVerificationClause(cid: "c1", issueID: "BACK-1", reason: "asserts landing's own output")]
        )))
        let dispatch = ScriptedVerifierDispatch([
            routeOther: .answer(both), routeThird: .judgeAll()
        ])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        #expect(try rejections(world).map(\.cause) == [.invalidOutput])
    }
}
