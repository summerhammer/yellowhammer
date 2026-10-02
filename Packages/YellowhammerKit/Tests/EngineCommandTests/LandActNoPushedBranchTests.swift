import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// risks OQ104, OQ107 (glossary: No-Pushed-Branch Outcome): a lane whose push reports no completed work,
// or a touched repository no Card names, is recorded once and leaves N; at N = 0 the Cycle is never
// archived. Stub seams, real mode unless the test says rehearsal.

private struct ThrowingArchiveCycle: CycleArchiving {
    struct ArchiveError: Error {}

    func archive(_ context: LandActFeatureContext) async throws {
        throw ArchiveError()
    }
}

private func outcomeRepositories(_ journal: JournalStore) throws -> [String] {
    try journal.events(ofType: .noPushedBranchOutcome).compactMap {
        if case .noPushedBranchOutcome(_, _, let repository) = $0.event { return repository }
        return nil
    }
}

private func archiveStep(_ journal: JournalStore) throws -> (outcome: LandStepOutcome, detail: String?)? {
    for record in try journal.events(ofType: .landStep).reversed() {
        if case .landStep(.archiveCycle, _, let outcome, let detail) = record.event { return (outcome, detail) }
    }
    return nil
}

private func invoke(
    _ act: LandAct, journal: JournalStore, runID: RunID, mode: NightMode = .real
) async throws {
    let invocation = EngineInvocation(
        act: .land, mode: mode, nightStart: landNightStart, journal: journal, trigger: .scheduled,
        runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
    )
    try await invocation.run()
}

@Suite("Land Act: No-Pushed-Branch Outcome (OQ104, OQ107)")
struct LandActNoPushedBranchTests {
    @Test("One lane with no completed work: one outcome for it, no pull request, the Cycle lands, N shrinks")
    func oneLaneNoCompletedWork() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log, noCompletedWork: ["mobile"]),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: log)
        )
        try await invoke(act, journal: journal, runID: runID)

        #expect(try outcomeRepositories(journal) == ["mobile"])
        #expect(log.all.contains("openPullRequest:backend"))
        #expect(!log.all.contains("openPullRequest:mobile"))
        #expect(log.all.contains("archiveCycle"))
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.touchedRepositories(featureID: land.featureID) == ["backend", "mobile"])
        #expect(try journal.pushedRepositories(featureID: land.featureID) == ["backend"])
    }

    @Test("A retried firing after a Feature-scoped fault leaves exactly one outcome event")
    func retriedFiringRecordsOnce() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let firstRun = RunID()
        try claimLandLease(journal, runID: firstRun)
        let land = try LandFixture.make(journal, runID: firstRun, worktrees: false)

        let log = LandCallLog()
        let verification = StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true))
        let push = StubPush(log: log, noCompletedWork: ["mobile"])
        let faulting = LandAct(
            mergeTest: StubMergeTest(log: log), push: push, verification: verification,
            archiveCycle: ThrowingArchiveCycle()
        )
        await #expect(throws: (any Error).self) {
            try await invoke(faulting, journal: journal, runID: firstRun)
        }
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try outcomeRepositories(journal) == ["mobile"])

        let healthy = LandAct(
            mergeTest: StubMergeTest(log: log), push: push, verification: verification,
            archiveCycle: StubArchiveCycle(log: log)
        )
        try await invoke(healthy, journal: journal, runID: RunID())

        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try outcomeRepositories(journal) == ["mobile"])
    }

    @Test("An outcome already recorded and then superseded by a push is never recorded again on a retry")
    func supersededOutcomeIsNotRecordedAgain() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let firstRun = RunID()
        try claimLandLease(journal, runID: firstRun)
        let land = try LandFixture.make(journal, runID: firstRun, worktrees: false)

        let log = LandCallLog()
        let verification = StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true))
        let push = StubPush(log: log, noCompletedWork: ["mobile"])
        let faulting = LandAct(
            mergeTest: StubMergeTest(log: log), push: push, verification: verification,
            archiveCycle: ThrowingArchiveCycle()
        )
        await #expect(throws: (any Error).self) {
            try await invoke(faulting, journal: journal, runID: firstRun)
        }
        #expect(try outcomeRepositories(journal) == ["mobile"])

        // The Operator answered a Card and the lane then pushed: the record is superseded.
        try journal.write { database in
            try database.execute(
                sql: """
                INSERT INTO worktree (feature_id, repository, worktree_id, path, created_at, released_at, pushed_commit)
                VALUES (?, 'mobile', 'wt-mobile', '/tmp/mobile', ?, ?, 'abc123')
                """,
                arguments: [land.featureID, JournalStore.timestamp(landEpoch), JournalStore.timestamp(landEpoch)]
            )
        }
        #expect(try journal.noPushedBranchRepositories(featureID: land.featureID).isEmpty)
        #expect(try journal.hasNoPushedBranchOutcomeRecord(featureID: land.featureID, repository: "mobile"))

        let healthy = LandAct(
            mergeTest: StubMergeTest(log: log), push: push, verification: verification,
            archiveCycle: StubArchiveCycle(log: log)
        )
        try await invoke(healthy, journal: journal, runID: RunID())

        #expect(try outcomeRepositories(journal) == ["mobile"])
    }

    @Test("A touched repository no Card names gets the outcome, once, in real and in rehearsal mode")
    func laneLessRepositoryGetsOutcome() async throws {
        for mode in [NightMode.real, NightMode.rehearsal] {
            let fixture = try OutboxJournalFixture()
            let journal = try fixture.open()
            let runID = RunID()
            try claimLandLease(journal, runID: runID, mode: mode)
            let land = try LandFixture.make(journal, runID: runID, worktrees: false)
            try recordTouchedRepositories(journal, featureID: land.featureID, repositories: ["web"])

            let log = LandCallLog()
            let act = LandAct(mergeTest: StubMergeTest(log: log), push: StubPush(log: log))
            try await invoke(act, journal: journal, runID: runID, mode: mode)

            #expect(try outcomeRepositories(journal) == ["web"])
            #expect(!log.all.contains { $0.hasSuffix(":web") })
            #expect(try journal.touchedRepositories(featureID: land.featureID) == ["backend", "mobile", "web"])
            #expect(try journal.pushedRepositories(featureID: land.featureID) == ["backend", "mobile"])
            #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        }
    }

    @Test("Rehearsal mode with Cards in every lane records no outcome: N is every touched repository")
    func rehearsalRecordsNoOutcomeForLanesWithCards() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID, mode: .rehearsal)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log, noCompletedWork: ["backend", "mobile"])
        )
        try await invoke(act, journal: journal, runID: runID, mode: .rehearsal)

        #expect(!log.all.contains { $0.hasPrefix("push") })
        #expect(try outcomeRepositories(journal).isEmpty)
        #expect(try journal.pushedRepositories(featureID: land.featureID) == ["backend", "mobile"])
    }

    @Test("Every lane with no completed work and an all-met verdict: the Cycle is not archived, and still lands")
    func nEqualsZeroDoesNotArchive() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log, noCompletedWork: ["backend", "mobile"]),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            returnFeature: StubReturnFeature(log: log),
            archiveCycle: StubArchiveCycle(log: log)
        )
        try await invoke(act, journal: journal, runID: runID)

        #expect(!log.all.contains("archiveCycle"))
        #expect(!log.all.contains("returnFeature"))
        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        let step = try #require(try archiveStep(journal))
        #expect(step.outcome == .skipped)
        #expect(step.detail == "no repository pushed a Feature Branch")
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.inFlightFeature() != nil)
        #expect(try journal.pushedRepositories(featureID: land.featureID).isEmpty)
        #expect(try journal.touchedRepositories(featureID: land.featureID) == ["backend", "mobile"])
    }

    @Test("Every lane with no completed work and an unmet verdict: the Feature is returned as before")
    func nEqualsZeroUnmetStillReturns() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        _ = try LandFixture.make(journal, runID: runID, worktrees: false)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log, noCompletedWork: ["backend", "mobile"]),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(
                log: log, verdict: VerificationVerdict(allClausesMet: false, unmetClauses: ["FEAT-1 cid-1"])
            ),
            returnFeature: StubReturnFeature(log: log),
            archiveCycle: StubArchiveCycle(log: log)
        )
        try await invoke(act, journal: journal, runID: runID)

        #expect(log.all.contains("returnFeature"))
        #expect(!log.all.contains("archiveCycle"))
    }
}
