import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// Issue #695 (spec: landing/overview; verification/return-a-feature-with-unmet-clauses): a Feature that
// Verification returns still lands its Cycle — landing is not reversed by a failed verification, the pull
// requests stay open and the Cycle is not archived. `cycleLanded` is therefore appended after the
// `return-feature` step, by design. What the later build and land firings record is the Feature's state:
// they idle with `featureReturned`, not `cycleAlreadyLanded`.

/// Returns the Feature the way the production seam does in the Journal: sets its state to `returned`.
private struct JournalReturnFeature: FeatureReturning {
    let log: LandCallLog

    func returnFeature(_ context: LandActFeatureContext, verdict: VerificationVerdict) async throws {
        log.add("returnFeature")
        try context.act.journal.recordFeatureReturned(featureID: context.feature.id, runID: context.act.runID)
    }
}

@Suite("Land Act: a returned Feature's Cycle still lands (issue #695)")
struct LandActReturnedFeatureTests {
    @Test("A returned Feature's Cycle lands after the return step; build and land then idle on featureReturned")
    func returnedFeatureLandsAndLaterFiringsNameIt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        try await runReturningLand(journal: journal, runID: runID)

        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try #require(try journal.inFlightFeature()).feature.isReturned)
        try expectCycleLandedAfterReturnStep(journal: journal, cycleID: land.cycleID)

        try await expectForcedLandIdlesOnFeatureReturned(journal: journal)
        try await expectForcedBuildIdlesOnFeatureReturned(journal: journal)
    }

    private func runReturningLand(journal: JournalStore, runID: RunID) async throws {
        let log = LandCallLog()
        let act = LandAct(
            verification: StubVerification(
                log: log, verdict: VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])
            ),
            returnFeature: JournalReturnFeature(log: log),
            archiveCycle: StubArchiveCycle(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )
        try await invocation.run()
        #expect(log.all.contains("returnFeature"))
        #expect(!log.all.contains("archiveCycle"))
    }

    /// The by-design order: the `return-feature` step completes, then the Cycle is recorded landed.
    private func expectCycleLandedAfterReturnStep(journal: JournalStore, cycleID: Int64) throws {
        let events = try journal.events()
        let returned = try #require(
            events.firstIndex { record in
                if case .landStep(.returnFeature, nil, .completed, _) = record.event { return true }
                return false
            }
        )
        let landed = try #require(events.firstIndex { $0.event == .cycleLanded(cycleID: cycleID) })
        #expect(returned < landed)
    }

    private func lastIdleReason(_ journal: JournalStore) throws -> ActIdleReason? {
        guard case .actIdle(let reason) = try journal.events(ofType: .actIdle).last?.event else { return nil }
        return reason
    }

    /// A forced land: `EngineInvocation` skips the predicate, so the Act's own guard records the reason.
    private func expectForcedLandIdlesOnFeatureReturned(journal: JournalStore) async throws {
        let log = LandCallLog()
        let act = LandAct(verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)))
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .forced,
            runID: RunID(), workspace: ReconcilerFakeWorkspace(), work: act.work
        )
        try await invocation.run()
        #expect(log.all.isEmpty)
        #expect(try lastIdleReason(journal) == .featureReturned)
    }

    /// A forced build: likewise guarded by the Act itself, and runs no Card.
    private func expectForcedBuildIdlesOnFeatureReturned(journal: JournalStore) async throws {
        let runner = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .real, nightStart: landNightStart, journal: journal, trigger: .forced,
            runID: RunID(), work: BuildAct(cardRunner: runner).work
        )
        try await invocation.run()
        #expect(runner.seen.isEmpty)
        #expect(try lastIdleReason(journal) == .featureReturned)
    }
}
