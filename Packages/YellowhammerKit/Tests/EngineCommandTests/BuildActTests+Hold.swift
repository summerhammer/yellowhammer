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

/// A fake ``CardRunner`` that transitions one named Card straight to Blocked and leaves every other
/// Card untouched — so BACK-1 ends this Act Blocked (not Done, and not simply unreached), which is
/// what makes the hold, rather than an unrelated lane break, the reason BACK-2 never runs.
private struct BlockingRunner: CardRunner {
    let blockingIssueID: String
    let log: CallLog

    func run(card: CardRecord, in lane: RepoLane, context: BuildActContext, readiness: CardReadiness) async throws {
        log.add(card.issueID)
        guard card.issueID == blockingIssueID else { return }
        _ = try context.act.journal.transitionCard(
            cardID: card.id, to: .blocked, blockReason: .routeFailure,
            runID: context.act.runID, act: context.act.act, nightID: context.act.night.id
        )
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

        // Act 1: BACK-1 ends Blocked (not Done — and not merely unreached by a lane break), so BACK-2
        // is held: the CardRunner never sees it.
        let firstRunID = RunID()
        try claimBuildActLease(journal, runID: firstRunID, now: buildActEpoch)
        let firstLog = CallLog()
        let firstInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .scheduled, runID: firstRunID,
            work: BuildAct(cardRunner: BlockingRunner(blockingIssueID: "BACK-1", log: firstLog)).work
        )
        try await firstInvocation.run()

        #expect(firstLog.all == ["BACK-1"])
        #expect(try journal.card(id: back1).state == .blocked)
        #expect(try journal.card(id: back2).state == .todo)

        // Between Acts: BACK-1 reaches Done — "Done at the start of a later build Act" (c3) — with no
        // Card run involved, so the only question left is whether the lane loop re-reads it.
        let secondRunID = RunID()
        try claimBuildActLease(journal, runID: secondRunID, now: buildActEpoch.addingTimeInterval(60))
        _ = try journal.transitionCard(
            cardID: back1, to: .done, runID: secondRunID, act: .build, nightID: nil
        )

        // Act 2: an ordinary runner. The lane loop re-reads BACK-1's current state through the
        // Journal — not the stale lane snapshot — finds it Done, and runs the held BACK-2.
        let secondRecorder = RecordingCardRunner()
        let secondInvocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal,
            trigger: .forced, runID: secondRunID, work: BuildAct(cardRunner: secondRecorder).work
        )
        try await secondInvocation.run()

        #expect(secondRecorder.seen.map(\.issueID) == ["BACK-2"])
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
