import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// spec ruling OQ182 (2026-10-22): the build Act's same-repository hold, exercised end to end through a
// real `EngineInvocation`, across Acts (c3) and across repositories (c4). Fixture helpers
// (`buildActBranch`, `buildActNightStart`, `buildActEpoch`, `RecordingCardRunner`) are shared with
// BuildActTests.swift.

private struct HoldTestLeaseNotClaimed: Error {}

/// Claims the build Act's lease for one test's invocation, failing loudly rather than silently if it
/// is somehow already held — the lease-claim boilerplate every test in this file otherwise repeats.
private func claimBuildActLease(_ journal: JournalStore, runID: RunID, now: Date) throws {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: now) else {
        throw HoldTestLeaseNotClaimed()
    }
}

@Suite("Build Act's same-repository hold (OQ182)")
struct BuildActHoldTests {
    @Test("""
    A Card held because its predecessor never reached Done stays Todo across Acts; once the predecessor \
    reaches Done in a later Act, the held Card runs in that same Act
    """)
    func heldCardRunsOnceItsPredecessorReachesDoneInALaterAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let back1 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let back2 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .todo
        )

        // Act 1: the runner throws for "backend" before it can transition BACK-1 to Done — an engine
        // fault that leaves BACK-1 exactly as it stood (Todo), so BACK-2 is held and never reached.
        let firstRunID = RunID()
        try claimBuildActLease(journal, runID: firstRunID, now: buildActEpoch)
        let firstRecorder = RecordingCardRunner(throwingFor: ["backend"])
        let firstInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: firstRunID, work: BuildAct(cardRunner: firstRecorder).work
        )
        await #expect(throws: BuildActError.self) {
            try await firstInvocation.run()
        }

        #expect(firstRecorder.seen.map(\.issueID) == ["BACK-1"])
        #expect(try journal.card(id: back1).state == .todo)
        #expect(try journal.card(id: back2).state == .todo)

        // Act 2: an ordinary runner. BACK-1 has no predecessor, so it runs and reaches Done; the lane
        // loop then re-reads BACK-1's current state through the Journal — not the stale lane snapshot —
        // finds it Done, and runs BACK-2 too, in the same Act.
        let secondRunID = RunID()
        try claimBuildActLease(journal, runID: secondRunID, now: buildActEpoch.addingTimeInterval(60))
        let secondRecorder = RecordingCardRunner()
        let secondInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .forced, runID: secondRunID, work: BuildAct(cardRunner: secondRecorder).work
        )
        try await secondInvocation.run()

        #expect(secondRecorder.seen.map(\.issueID) == ["BACK-1", "BACK-2"])
        #expect(try journal.card(id: back1).state == .done)
        #expect(try journal.card(id: back2).state == .done)
    }

    @Test("""
    A Blocked Card in one repository's lane holds its own lane's successor, but never another \
    repository's lane
    """)
    func blockedCardInOneLaneDoesNotHoldAnotherLane() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        _ = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .blocked
        )
        let back2 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", state: .todo
        )
        let mobile1 = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile", state: .todo
        )

        let runID = RunID()
        try claimBuildActLease(journal, runID: runID, now: buildActEpoch)
        let recorder = RecordingCardRunner()
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: runID, work: BuildAct(cardRunner: recorder).work
        )

        try await invocation.run()

        // BACK-2 is held by the Blocked BACK-1, in its own lane; the mobile lane runs independently.
        #expect(recorder.seen.map(\.issueID) == ["MOB-1"])
        #expect(try journal.card(id: back2).state == .todo)
        #expect(try journal.card(id: mobile1).state == .done)
    }
}
