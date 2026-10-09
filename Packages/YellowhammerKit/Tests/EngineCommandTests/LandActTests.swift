import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P10.1: the land Act's sequencing skeleton, modelled on BuildAct. Per Repo Lane: merge test,
// push, open pull request, release Worktree, sequentially, in order. Then, if no lane faulted, the
// Feature-scoped Verification, return or archive. Rehearsal is a boundary the Act itself enforces on
// push and open-pull-request. The Cycle lands once per Cycle (risks OQ8). Shared fixtures and stub
// seams live in LandActFixtures.swift.

@Suite("Land Act (P10.1)")
struct LandActTests {
    @Test("Real mode, two lanes: exact order per lane, then Verification, then archive; the Cycle lands")
    func realModeRunsStepsInOrderAndLands() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        let calls = log.all
        #expect(calls.filter { $0.hasPrefix("mergeTest") }.count == 2)
        #expect(calls.filter { $0.hasPrefix("push") }.count == 2)
        #expect(calls.filter { $0.hasPrefix("openPullRequest") }.count == 2)
        #expect(calls.filter { $0 == "verification" }.count == 1)
        #expect(calls.filter { $0 == "archiveCycle" }.count == 1)
        #expect(!calls.contains("returnFeature"))

        // Per-lane order: merge test, then push; every push precedes Verification, which precedes every
        // pull request (its report is written into the once-written body).
        let backendMerge = try #require(calls.firstIndex(of: "mergeTest:backend"))
        let backendPush = try #require(calls.firstIndex(of: "push:backend"))
        let mobilePush = try #require(calls.firstIndex(of: "push:mobile"))
        let backendPR = try #require(calls.firstIndex(of: "openPullRequest:backend"))
        let mobilePR = try #require(calls.firstIndex(of: "openPullRequest:mobile"))
        #expect(backendMerge < backendPush)
        let verificationIndex = try #require(calls.firstIndex(of: "verification"))
        #expect(backendPush < verificationIndex)
        #expect(mobilePush < verificationIndex)
        #expect(verificationIndex < backendPR)
        #expect(verificationIndex < mobilePR)
        let archiveIndex = try #require(calls.firstIndex(of: "archiveCycle"))
        #expect(verificationIndex < archiveIndex)

        // Both lanes' Worktrees were released once their push completed.
        let held = try heldWorktreeIDs(journal, featureID: land.featureID)
        #expect(held == ["backend": false, "mobile": false])

        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.events(ofType: .cycleLanded).count == 1)
    }

    @Test("Verdict unmet: return is called, archive is not; the Cycle still lands")
    func unmetVerdictCallsReturnNotArchive() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(
                log: log, verdict: VerificationVerdict(allClausesMet: false, unmetClauses: ["cid-1"])
            ),
            returnFeature: StubReturnFeature(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        #expect(log.all.contains("returnFeature"))
        #expect(!log.all.contains("archiveCycle"))
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))

        let steps = try journal.events(ofType: .landStep)
        let returnStep = try #require(steps.first {
            if case .landStep(.returnFeature, _, _, _) = $0.event { return true }
            return false
        })
        guard case .landStep(_, _, let outcome, _) = returnStep.event else {
            Issue.record("expected landStep")
            return
        }
        #expect(outcome == .completed)
        let archiveStep = try #require(steps.first {
            if case .landStep(.archiveCycle, _, _, _) = $0.event { return true }
            return false
        })
        guard case .landStep(_, _, let archiveOutcome, _) = archiveStep.event else {
            Issue.record("expected landStep")
            return
        }
        #expect(archiveOutcome == .skipped)
    }

    @Test("Rehearsal mode: push and open pull request are never called, recorded rehearsalBoundary")
    func rehearsalNeverPushesOrOpensPullRequests() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID, mode: .rehearsal)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .rehearsal, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        #expect(log.all.filter { $0.hasPrefix("mergeTest") }.count == 2)
        #expect(!log.all.contains { $0.hasPrefix("push") })
        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        #expect(log.all.contains("verification"))
        #expect(log.all.contains("archiveCycle"))

        let steps = try journal.events(ofType: .landStep)
        let pushSteps = steps.filter {
            if case .landStep(.push, _, _, _) = $0.event { return true }
            return false
        }
        for step in pushSteps {
            guard case .landStep(_, _, let outcome, _) = step.event else { continue }
            #expect(outcome == .rehearsalBoundary)
        }
        let prSteps = steps.filter {
            if case .landStep(.openPullRequest, _, _, _) = $0.event { return true }
            return false
        }
        for step in prSteps {
            guard case .landStep(_, _, let outcome, _) = step.event else { continue }
            #expect(outcome == .rehearsalBoundary)
        }

        // Worktrees stay held in rehearsal — never pushed.
        let held = try heldWorktreeIDs(journal, featureID: land.featureID)
        #expect(held == ["backend": true, "mobile": true])
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
    }

    @Test("A push reporting not-pushed is outstanding: no Verification or pull request, Worktrees held, unlanded")
    func notPushedKeepsWorktreeHeldAndSkipsPullRequest() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log, notPushed: ["backend"]),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        #expect(!log.all.contains("verification"))
        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        #expect(!log.all.contains("archiveCycle"))

        let held = try heldWorktreeIDs(journal, featureID: land.featureID)
        #expect(held == ["backend": true, "mobile": true])
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.events(ofType: .cycleLanded).isEmpty)

        let backendPush = try #require(try recordedLandSteps(journal, .push, repository: "backend").first)
        #expect(backendPush.outcome == .failed)
        let pullRequests = try recordedLandSteps(journal, .openPullRequest)
        #expect(pullRequests.count == 2)
        #expect(pullRequests.allSatisfy { $0.outcome == .skipped && $0.detail == "a required push is outstanding" })
    }

    @Test("A merge test reporting a conflict does not stop the lane")
    func mergeConflictDoesNotStopTheLane() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log, conflict: true),
            push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        #expect(log.all.filter { $0.hasPrefix("push") }.count == 2)
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
    }

    @Test("A throwing push in one lane: Verification is not called, no lane opens a pull request")
    func throwingPushFaultsOneLaneOnly() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log, throwing: ["backend"]),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
            archiveCycle: StubArchiveCycle(log: log)
        )
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        await #expect(throws: (any Error).self) {
            try await invocation.run()
        }

        // Lane A (backend) stopped after its push threw: no pull request, no release.
        #expect(!log.all.contains("openPullRequest:backend"))
        // Lane B (mobile) pushed, but Verification (wired) never ran, so its pull request is skipped.
        #expect(log.all.contains("push:mobile"))
        #expect(!log.all.contains("openPullRequest:mobile"))
        #expect(!log.all.contains("verification"))
        #expect(!log.all.contains("archiveCycle"))
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))

        let held = try heldWorktreeIDs(journal, featureID: land.featureID)
        #expect(held["mobile"] == true)
        #expect(held["backend"] == true)
    }

    @Test("Every seam nil: every step is recorded not-wired, and the Cycle still lands")
    func everySeamNilRecordsNotWiredAndLands() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID, worktrees: false)

        let act = LandAct()
        let invocation = EngineInvocation(
            act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
            runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
        )

        try await invocation.run()

        // Every seam-backed step records not-wired; the release-Worktree step is not itself a seam and
        // is recorded skipped, since no Worktree is held in this fixture.
        let steps = try journal.events(ofType: .landStep)
        for record in steps {
            guard case .landStep(let step, _, let outcome, _) = record.event else { continue }
            if step == .releaseWorktree {
                #expect(outcome == .skipped)
            } else {
                #expect(outcome == .notWired)
            }
        }
        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
    }
}
