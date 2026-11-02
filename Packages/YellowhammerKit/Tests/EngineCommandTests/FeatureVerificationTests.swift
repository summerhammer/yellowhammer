import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P10.5 (verification/verify-a-feature-clause-by-clause): who verifies, what the engine decides
// itself, and that a Cycle is judged once. Wiring, routing and arithmetic only — never that a verdict a
// model reached is correct.

@Suite("Verification: a different agent, clause by clause (P10.5)")
struct FeatureVerificationTests {
    // MARK: - Different agent

    @Test("The verifier request goes to a Route that ran none of the Cycle's Attempts")
    func verifierGoesToADifferentRoute() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(dispatch.requests.map(\.route) == [routeOther])
        #expect(dispatch.requests.first?.pass == .verifier)
        #expect(verdict.allClausesMet)
        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        #expect(recorded.route == routeOther.description)
    }

    @Test("With only the writing Route available, Verification faults, dispatches nothing, records nothing")
    func onlyTheWriterIsAFault() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let dispatch = ScriptedVerifierDispatch([routeWriter: .judgeAll()])

        do {
            _ = try await world.verification(resolver: verificationResolver(primary: routeWriter), dispatch: dispatch)
                .verify(world.featureContext)
            Issue.record("expected VerificationDispatchFault")
        } catch let fault as VerificationDispatchFault {
            #expect(fault.reason.contains("wrote the code"))
        }

        #expect(dispatch.requests.isEmpty)
        #expect(try world.journal.featureVerification(cycleID: world.cycleID) == nil)
        #expect(try tableRowCount(world.journal, table: "feature_verification") == 0)
        #expect(try tableRowCount(world.journal, table: "clause_verification") == 0)
    }

    @Test("A Route whose result omits a clause is passed over for the next fallback")
    func fallbackWalksPastAnIncompleteResult() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "BACK-1", cid: "c2")
        try world.addAttempt(card: "BACK-1", route: routeWriter)
        let partial = DispatchResult.verifier(VerifierResult(outcome: .reported(clauses: [
            VerifiedClause(cid: "c1", issueID: "BACK-1", verdict: .met, whatWasChecked: "x", interpretation: "y")
        ])))
        let dispatch = ScriptedVerifierDispatch([routeOther: .answer(partial), routeThird: .judgeAll()])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(dispatch.requests.map(\.route) == [routeOther, routeThird])
        #expect(verdict.allClausesMet)
    }

    @Test("Refusals, non-zero exits and failed results each fall through; a crash ends Verification")
    func capabilityFailuresFallThroughAndACrashFaults() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let failed = DispatchResult.verifier(VerifierResult(outcome: .failed(reason: "cannot read")))
        let dispatch = ScriptedVerifierDispatch([
            routeWriter: .refuse, routeOther: .exit(2), routeThird: .answer(failed)
        ])
        let resolver = verificationResolver(primary: routeWriter, fallbacks: [routeOther, routeThird])
        await #expect(throws: VerificationDispatchFault.self) {
            try await world.verification(resolver: resolver, dispatch: dispatch).verify(world.featureContext)
        }
        #expect(dispatch.requests.map(\.route) == [routeWriter, routeOther, routeThird])

        let crashing = ScriptedVerifierDispatch([routeWriter: .crash, routeOther: .judgeAll()])
        await #expect(throws: VerificationDispatchFault.self) {
            try await world.verification(resolver: resolver, dispatch: crashing).verify(world.featureContext)
        }
        #expect(crashing.requests.map(\.route) == [routeWriter])
        #expect(try world.journal.featureVerification(cycleID: world.cycleID) == nil)
    }

    @Test("A verifier usage refusal backs off its CLI and tries another CLI")
    func usageRefusalFallsBack() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .usageLimit, routeThird: .judgeAll()])
        let resolver = verificationResolver(primary: routeOther, fallbacks: [routeThird])
        _ = try await world.verification(resolver: resolver, dispatch: dispatch).verify(world.featureContext)
        #expect(dispatch.requests.map(\.route) == [routeOther, routeThird])
        #expect(try world.journal.events(ofType: .routeUsageLimited).count == 1)
        #expect(try world.journal.backingOffCLIs() == [routeOther.cli])
    }

    // MARK: - Engine-decided outcomes

    @Test("A clause whose citation does not resolve is unresolved, never sent to the agent, never met")
    func unresolvedCitationIsTheEnginesCall() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "BACK-1", cid: "c2", location: "gone/story")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        let verification = world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
        let verdict = try await verification.verify(world.featureContext)

        #expect(dispatch.dispatchedClauses == [["BACK-1 c1"]])
        #expect(!verdict.allClausesMet)
        #expect(verdict.unresolvedClauses == ["BACK-1 c2"])
        #expect(verdict.unmetClauses.isEmpty)
        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        let unresolved = try #require(recorded.clauses.first { $0.cid == "c2" })
        #expect(unresolved.verdict == .unresolved)
        #expect(unresolved.judgedBy == .engine)
        #expect(unresolved.whatWasChecked.contains("Specification Author"))
        #expect(unresolved.whatWasChecked.contains("not unfinished work"))
    }

    @Test("Clauses of a Card that did not complete are unmet, judged by the engine, and never dispatched")
    func incompleteCardsClausesAreUnmet() async throws {
        let world = try await VerificationWorld(cards: [
            VerificationCard("BACK-1", "backend", .done), VerificationCard("BACK-2", "backend", .blocked),
            VerificationCard("MOB-1", "mobile", .waitingOnYou),
            VerificationCard("MOB-2", "mobile", .shelved)
        ])
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "BACK-2", cid: "c1")
        try world.addClause(issue: "MOB-1", cid: "c1")
        try world.addClause(issue: "MOB-2", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        let verification = world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
        let verdict = try await verification.verify(world.featureContext)

        // Only the Done Card's clause reached the agent, and it came back met — yet the Feature is not.
        #expect(dispatch.dispatchedClauses == [["BACK-1 c1"]])
        #expect(!verdict.allClausesMet)
        #expect(verdict.unmetClauses == ["BACK-2 c1", "MOB-1 c1"])
        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        // The Shelved Card's clause is not judged at all.
        #expect(recorded.clauses.map { "\($0.issueID) \($0.cid)" } == ["BACK-1 c1", "BACK-2 c1", "MOB-1 c1"])
        let blocked = try #require(recorded.clauses.first { $0.issueID == "BACK-2" })
        #expect(blocked.judgedBy == .engine)
        #expect(blocked.whatWasChecked.contains("Blocked"))
        #expect(blocked.interpretation == "not verified: the work this clause covers did not land")
    }

    @Test("When every clause is decided by the engine, no verifier is dispatched and the Route is nil")
    func allEngineDecidedDispatchesNothing() async throws {
        let world = try await VerificationWorld(cards: [VerificationCard("BACK-1", "backend", .blocked)])
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "FEAT-1", cid: "c1", location: "gone/story")
        let dispatch = ScriptedVerifierDispatch([:])

        let verification = world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
        let verdict = try await verification.verify(world.featureContext)

        #expect(dispatch.requests.isEmpty)
        #expect(!verdict.allClausesMet)
        #expect(try world.journal.featureVerification(cycleID: world.cycleID)?.route == nil)
    }

    @Test("Without configured repositories Verification faults rather than marking every clause unresolved")
    func noRepositoriesIsAFault() async throws {
        let world = try await VerificationWorld(repositories: nil)
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        await #expect(throws: VerificationFault.self) {
            try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
                .verify(world.featureContext)
        }
        #expect(dispatch.requests.isEmpty)
        #expect(try world.journal.featureVerification(cycleID: world.cycleID) == nil)
    }

    @Test("A Cycle with no clause at all is a fault, not a pass")
    func noClausesIsAFault() async throws {
        let world = try await VerificationWorld()
        await #expect(throws: VerificationFault.self) {
            try await world.verification(
                resolver: verificationResolver(primary: routeOther), dispatch: ScriptedVerifierDispatch([:])
            ).verify(world.featureContext)
        }
    }

    // MARK: - Record

    @Test("Provenance travels from the clause table to the persisted row and the rendered line")
    func provenanceTravels() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "FEAT-1", cid: "c1", provenance: "Author-supplied")
        try world.addClause(issue: "BACK-1", cid: "c1", provenance: "machine-found")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)

        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        #expect(recorded.clauses.map(\.citationProvenance) == ["Author-supplied", "machine-found"])
        let lines = recorded.clauses.map(VerificationReport.line(for:))
        #expect(lines[0].contains("[Author-supplied]"))
        #expect(lines[1].contains("[machine-found]"))
    }

    @Test("Feature-level clauses come first, then Cards in authored order; an invalidated clause says so")
    func orderAndInvalidation() async throws {
        let world = try await VerificationWorld(cards: [
            VerificationCard("BACK-1", "backend", .done), VerificationCard("MOB-1", "mobile", .done)
        ])
        try world.addClause(issue: "MOB-1", cid: "c1")
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "FEAT-1", cid: "c1")
        try world.journal.invalidateClause(issueID: "BACK-1", cid: "c1", cause: "text_edited")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)

        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        #expect(recorded.clauses.map(\.issueID) == ["FEAT-1", "BACK-1", "MOB-1"])
        let line = VerificationReport.line(for: try #require(recorded.clauses.first { $0.issueID == "BACK-1" }))
        #expect(line.contains("(invalidated: text_edited)"))
    }

    @Test("A Cycle is judged once: a second verify dispatches nothing and returns the same verdict")
    func judgedOnce() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "BACK-1", cid: "c2")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll(unmet: ["BACK-1 c2"])])
        let verification = world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)

        let first = try await verification.verify(world.featureContext)
        let second = try await verification.verify(world.featureContext)

        #expect(dispatch.requests.count == 1)
        #expect(first == second)
        #expect(!second.allClausesMet)
        #expect(second.unmetClauses == ["BACK-1 c2"])
        #expect(try world.journal.events(ofType: .featureVerified).count == 1)
        // The report write is queued under one deterministic key, so the replay adds no second row.
        #expect(try tableRowCount(world.journal, table: "outbox") == 1)
    }

    @Test("The recorded event carries counts only, and the dispatch is journaled with its Route")
    func eventsRecordCountsAndDispatch() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "BACK-1", cid: "c2")
        try world.addClause(issue: "BACK-1", cid: "c3", location: "gone/story")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll(unmet: ["BACK-1 c2"])])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)

        let verified = try world.journal.events(ofType: .featureVerified).map(\.event)
        #expect(verified == [.featureVerified(cycleID: world.cycleID, met: 1, unmet: 1, unresolved: 1)])
        let dispatched = try world.journal.events(ofType: .authoringDispatched).map(\.event)
        #expect(dispatched == [
            .authoringDispatched(pass: .verifier, route: routeOther.description, ordinal: 1, fixture: nil)
        ])
    }

    @Test("The instruction names the specification source, and each touched repository's code directory")
    func instructionCarriesPaths() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1", text: "Returns 404 for a missing id.")
        try world.journal.recordWorktree(
            featureID: world.featureID, repository: "backend", worktreeID: "wt-backend", path: "/wt/backend",
            runID: world.featureContext.act.runID
        )
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])

        _ = try await world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
            .verify(world.featureContext)

        let request = try #require(dispatch.requests.first)
        #expect(request.worktreePath == "/repos/spec")
        #expect(request.additionalReadableDirectories == ["/wt/backend"])
        #expect(request.issueID == "verification")
        let text = request.instruction.render()
        #expect(text.contains("BACK-1 c1: Returns 404 for a missing id."))
        #expect(text.contains("Spec Citation: resolvable/story"))
        #expect(text.contains("Finished code: /wt/backend"))
        #expect(text.contains("Feature Branch: yh-proj-feat"))
        #expect(text.contains("Specification path: /repos/spec"))
    }

    // MARK: - Dropped clauses (OQ157)

    @Test(
        "Verdict with dropped clauses: met+dropped verified, unmet+dropped returns naming unmet, all-dropped unverified"
    )
    func verdictWithDroppedClauses() {
        let metClause = ClauseVerificationRecord(
            issueID: "BACK-1", cid: "c1", level: "card", text: "Returns 404.", locationID: "epic/story",
            citationProvenance: "machine-found", verdict: .met, whatWasChecked: "checked handler",
            interpretation: "path param", judgedBy: .agent
        )
        let unmetClause = ClauseVerificationRecord(
            issueID: "BACK-1", cid: "c2", level: "card", text: "Returns 200.", locationID: "epic/story",
            citationProvenance: "machine-found", verdict: .unmet, whatWasChecked: "checked handler",
            interpretation: "returns 500", judgedBy: .agent
        )
        let droppedClause = ClauseVerificationRecord(
            issueID: "FEAT-1", cid: "c4", level: "feature",
            text: "A Night ships its change as a pushed Feature Branch with one pull request. (G1)",
            locationID: "vision/risks", citationProvenance: "Author-supplied",
            droppedReason: "asserts landing's own output"
        )

        // 1. Met + dropped: all clauses met
        let metAndDropped = FeatureVerificationRecord(
            id: 1, featureID: 1, cycleID: 1, route: nil, nightID: 1, runID: RunID(),
            verifiedAt: Date(), clauses: [metClause, droppedClause], judgedCheckouts: []
        )
        let verdict1 = FeatureVerification.verdict(of: metAndDropped)
        #expect(verdict1.allClausesMet)
        #expect(verdict1.unmetClauses.isEmpty)
        #expect(verdict1.unresolvedClauses.isEmpty)
        #expect(verdict1.notCheckedClauses.isEmpty)
        #expect(CycleArchive.allClausesMet(metAndDropped))

        // 2. Unmet + dropped: returned, naming only the unmet clause
        let unmetAndDropped = FeatureVerificationRecord(
            id: 2, featureID: 1, cycleID: 1, route: nil, nightID: 1, runID: RunID(),
            verifiedAt: Date(), clauses: [unmetClause, droppedClause], judgedCheckouts: []
        )
        let verdict2 = FeatureVerification.verdict(of: unmetAndDropped)
        #expect(!verdict2.allClausesMet)
        #expect(verdict2.unmetClauses == ["BACK-1 c2"])
        #expect(verdict2.unresolvedClauses.isEmpty)
        #expect(verdict2.notCheckedClauses.isEmpty)
        #expect(!CycleArchive.allClausesMet(unmetAndDropped))

        // 3. All dropped: nothing judged, not verified
        let allDropped = FeatureVerificationRecord(
            id: 3, featureID: 1, cycleID: 1, route: nil, nightID: 1, runID: RunID(),
            verifiedAt: Date(), clauses: [droppedClause], judgedCheckouts: []
        )
        let verdict3 = FeatureVerification.verdict(of: allDropped)
        #expect(!verdict3.allClausesMet)
        #expect(verdict3.unmetClauses.isEmpty)
        #expect(verdict3.unresolvedClauses.isEmpty)
        #expect(verdict3.notCheckedClauses.isEmpty)
        #expect(!CycleArchive.allClausesMet(allDropped))
    }

    @Test("Dropped clauses are excluded from the four featureVerified event counts (OQ157)")
    func droppedClausesExcludedFromEventCounts() throws {
        let metClause = ClauseVerificationRecord(
            issueID: "BACK-1", cid: "c1", level: "card", text: "T1", locationID: "L1",
            citationProvenance: "machine-found", verdict: .met, whatWasChecked: "W1",
            interpretation: "I1", judgedBy: .agent
        )
        let droppedClause = ClauseVerificationRecord(
            issueID: "FEAT-1", cid: "c4", level: "feature", text: "T4", locationID: "L4",
            citationProvenance: "Author-supplied", droppedReason: "asserts landing's own output"
        )
        let record = FeatureVerificationRecord(
            id: 1, featureID: 1, cycleID: 1, route: nil, nightID: 1, runID: RunID(),
            verifiedAt: Date(), clauses: [metClause, droppedClause], judgedCheckouts: []
        )

        let metCount = record.clauses.filter { $0.verdict == .met }.count
        let unmetCount = record.clauses.filter { $0.verdict == .unmet }.count
        let unresolvedCount = record.clauses.filter { $0.verdict == .unresolved }.count
        let notCheckedCount = record.clauses.filter { $0.verdict == .notChecked }.count

        #expect(metCount == 1)
        #expect(unmetCount == 0)
        #expect(unresolvedCount == 0)
        #expect(notCheckedCount == 0)

        let event = JournalEvent.featureVerified(
            cycleID: 1, met: metCount, unmet: unmetCount, unresolved: unresolvedCount, notChecked: notCheckedCount
        )
        #expect(event == .featureVerified(cycleID: 1, met: 1, unmet: 0, unresolved: 0, notChecked: 0))
    }

    @Test("One Author-supplied clause dropped, rest met: verified and report shows drop (OQ157)")
    func endToEndVerificationWithDroppedAuthorSuppliedClause() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1", provenance: "machine-found")
        try world.addClause(issue: "FEAT-1", cid: "c2", provenance: "Author-supplied")
        try world.addClause(issue: "FEAT-1", cid: "c3", provenance: "Author-supplied")

        let answer = DispatchResult.verifier(VerifierResult(outcome: .reported(
            clauses: [
                VerifiedClause(cid: "c1", issueID: "BACK-1", verdict: .met, whatWasChecked: "w1", interpretation: "i1"),
                VerifiedClause(cid: "c2", issueID: "FEAT-1", verdict: .met, whatWasChecked: "w2", interpretation: "i2")
            ],
            dropped: [
                DroppedVerificationClause(cid: "c3", issueID: "FEAT-1", reason: "asserts landing's own output")
            ]
        )))
        let dispatch = ScriptedVerifierDispatch([routeOther: .answer(answer)])
        let resolver = verificationResolver(primary: routeOther)

        let verdict = try await world.verification(resolver: resolver, dispatch: dispatch)
            .verify(world.featureContext)

        #expect(verdict.allClausesMet)
        #expect(verdict.unmetClauses.isEmpty)
        #expect(verdict.unresolvedClauses.isEmpty)
        #expect(verdict.notCheckedClauses.isEmpty)

        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        #expect(recorded.clauses.count == 3)
        let droppedRecord = try #require(recorded.clauses.first { $0.cid == "c3" && $0.issueID == "FEAT-1" })
        #expect(droppedRecord.verdict == nil)
        #expect(droppedRecord.droppedReason == "asserts landing's own output")
        #expect(droppedRecord.judgedBy == .agent)

        let reportLine = VerificationReport.line(for: droppedRecord)
        #expect(reportLine.contains("dropped: asserts landing's own output"))
        #expect(!reportLine.contains("· met"))
        #expect(!reportLine.contains("· unmet"))
    }
}
