import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.1; risks OQ8 (once per Cycle): once a Cycle has landed, neither a scheduled nor a forced
// land does anything more, and neither does build — even with a Card back in Todo. Split out of
// LandActTests.swift to keep that file under the file length limit.

@Suite("Land Act: once per Cycle (P10.1, OQ8)")
struct LandActOnceLandedTests {
    @Test("Once landed, a scheduled or forced land does nothing more; build likewise runs no Card")
    func onceLandedFurtherFiringsDoNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        try await runLand(journal: journal, runID: runID)
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))

        try await expectScheduledLandDoesNothing(journal: journal, cycleID: land.cycleID)
        try await expectForcedLandDoesNothing(journal: journal)
        try await expectBuildRunsNoCard(journal: journal, cycleID: land.cycleID)
    }

    private func runLand(journal: JournalStore, runID: RunID) async throws {
        let act = LandAct(
            verification: StubVerification(log: LandCallLog(), verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: LandCallLog())
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )
        try await invocation.run()
    }

    /// A scheduled land after landing: the trigger predicate is false.
    private func expectScheduledLandDoesNothing(journal: JournalStore, cycleID: Int64) async throws {
        let log = LandCallLog()
        let act = LandAct(verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)))
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), workspace: ReconcilerFakeWorkspace(), work: act.work
        )
        try await invocation.run()
        #expect(log.all.isEmpty)

        let idleEvents = try journal.events(ofType: .actIdle)
        guard case .actIdle(let reason) = try #require(idleEvents.last?.event) else {
            Issue.record("expected actIdle")
            return
        }
        #expect(reason == .cycleAlreadyLanded)
    }

    /// A forced land after landing: the Act itself guards it, since `EngineInvocation` only guards the
    /// predicate for a non-forced trigger.
    private func expectForcedLandDoesNothing(journal: JournalStore) async throws {
        let log = LandCallLog()
        let act = LandAct(verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)))
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .forced,
            runID: RunID(), workspace: ReconcilerFakeWorkspace(), work: act.work
        )
        try await invocation.run()
        #expect(log.all.isEmpty)
    }

    /// A build (scheduled or forced) on the landed Cycle with a Todo Card runs no Card.
    private func expectBuildRunsNoCard(journal: JournalStore, cycleID: Int64) async throws {
        try journal.write { db in
            try db.execute(
                sql: "UPDATE card SET state = ? WHERE cycle_id = ?",
                arguments: [CardState.todo.rawValue, cycleID]
            )
        }

        let scheduledRunner = RecordingCardRunner()
        let scheduledBuild = EngineInvocation(
            act: .build, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), work: BuildAct(cardRunner: scheduledRunner).work
        )
        try await scheduledBuild.run()
        #expect(scheduledRunner.seen.isEmpty)

        let forcedRunner = RecordingCardRunner()
        let forcedBuild = EngineInvocation(
            act: .build, mode: .real, nightStart: landNightStart, journal: journal, trigger: .forced,
            runID: RunID(), work: BuildAct(cardRunner: forcedRunner).work
        )
        try await forcedBuild.run()
        #expect(forcedRunner.seen.isEmpty)
    }
}
