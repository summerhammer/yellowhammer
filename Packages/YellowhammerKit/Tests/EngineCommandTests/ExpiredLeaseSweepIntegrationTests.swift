import Darwin
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// loop-state/reclaim-an-expired-lease (P8.10), continued: the scenarios that need real process-table
// fencing or a real build Act, split out of ExpiredLeaseSweepTests.swift to keep it under the file
// length limit. Shared fixtures (`makeReclaimFixture`, `reclaimEpoch`, `makeReclaimWorktreeDirectory`,
// ...) live there.

@Suite("ExpiredLeaseSweep integration (P8.10)")
struct ExpiredLeaseSweepIntegrationTests {
    @Test(
        "A lingering process with its cwd in the Worktree is fenced (killed) before the repost",
        .enabled(if: FileManager.default.fileExists(atPath: "/bin/sleep"))
    )
    func lingeringProcessIsFencedBeforeRepost() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let worktree = try makeReclaimWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: worktree)

        let process = try makeReconcilerSleepProcess(currentDirectory: worktree)
        defer { if process.isRunning { process.terminate() } }

        let fencer = ProcessFencer(pollInterval: .milliseconds(20), quiescenceTimeout: .seconds(5))
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }, fencer: fencer
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        #expect(!process.isRunning)
        // Fencing succeeded (quiescent), so the reclaim proceeded: the Card went back to Ready.
        #expect(try journal.card(id: card.cardID).state == .todo)
    }

    @Test(
        "A not-quiescent Worktree: no classification, no repost, Attempt still open, .cardReclaimDeferred recorded",
        .enabled(if: FileManager.default.fileExists(atPath: "/bin/sleep"))
    )
    func notQuiescentWorktreeDefersReclaim() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let worktree = try makeReclaimWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: worktree)

        let process = try makeReconcilerSleepProcess(currentDirectory: worktree)
        defer { if process.isRunning { process.terminate() } }

        // A `sendSignal` that never actually signals anything: the real sleep process survives every
        // "SIGKILL", so fencing genuinely times out not-quiescent — no faked FencingOutcome.
        let fencer = ProcessFencer(
            pollInterval: .milliseconds(20), quiescenceTimeout: .milliseconds(200), sendSignal: { _, _ in 0 }
        )
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }, fencer: fencer
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        #expect(process.isRunning)
        // Nothing was classified or reposted: the Card and its open Attempt are untouched.
        #expect(try journal.card(id: card.cardID).state == .inProgress)
        #expect(try journal.attemptHistory(cardID: card.cardID).openAttempt != nil)
        #expect(try journal.events(ofType: .cardReclaimed).isEmpty)

        let deferred = try journal.events(ofType: .cardReclaimDeferred)
        guard case .cardReclaimDeferred(let cardID, _, let previousRunID, let remaining) =
            try #require(deferred.first).event
        else {
            Issue.record("expected cardReclaimDeferred")
            return
        }
        #expect(cardID == card.cardID)
        #expect(previousRunID == deadRun)
        #expect(remaining > 0)

        process.terminate()
        process.waitUntilExit()
    }

    @Test("AC6: a Crashed-Unknown reclaim retries the same Route once, in the same build Act, against the same budget")
    func reclaimRetriesSameRouteInSameBuildAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let git = GitRunner()
        let worktrees = fixture.directory.appending(component: "worktrees", directoryHint: .isDirectory)
        try await initReconcilerGitRepo(at: worktrees.appending(component: "backend"), git: git)

        let runID = RunID()
        let deadRun = RunID()
        // `ExpiredLeaseSweep`'s default clock is the real wall clock inside a real `EngineInvocation`
        // (never injected here), so every lease timestamp below is relative to `Date()`, not a fixed
        // epoch — mirroring `buildActEpoch` elsewhere in this Suite.
        let now = Date()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: now) else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "E2E-FEAT")
        try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "E2E-1", repository: "backend", state: .inProgress
        )
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend",
            path: worktrees.appending(component: "backend").path(percentEncoded: false), runID: runID
        )
        // The engine died mid-Card: an open Attempt on the fixture's one Route, its Lease held by a run
        // that never heartbeated past the 600s TTL, and no result file behind it.
        _ = try journal.recordAttempt(cardID: cardID, route: cardRunOpus, runID: runID, act: .build, now: now)
        _ = try journal.claimCardLease(cardID: cardID, runID: deadRun, now: now.addingTimeInterval(-700))

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "E2E-1", description: nil)
        let board = ActBoard(
            reading: FakeReadingBoard([page()]), writing: boards.writing, provisioning: boards.provisioning
        )

        let rehearsal = RehearsalDispatch()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: rehearsal, check: RecordingCheck(log: CallLog()),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3, resetting: RecordingAttemptResetting()
        )
        let invocation = EngineInvocation(
            act: .build, mode: .rehearsal, nightStart: buildActNightStart, journal: journal, trigger: .scheduled,
            runID: runID, board: board, workspace: ReconcilerFakeWorkspace(), work: BuildAct(cardRunner: run).work
        )

        try await invocation.run()

        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.attempts.count == 2)
        let reclaimedAttempt = try #require(history.attempts.first)
        #expect(reclaimedAttempt.result == AttemptOutcome.crashedUnknown.rawValue)
        #expect(reclaimedAttempt.route == cardRunOpus)
        let retriedAttempt = try #require(history.attempts.last)
        #expect(retriedAttempt.route == cardRunOpus)
        #expect(retriedAttempt.result == AttemptOutcome.success.rawValue)
        #expect(try journal.card(id: cardID).state == .done)
        // A Crashed-Unknown never excludes its Route (the same Attempt budget, not a fresh one).
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)
        #expect(try journal.events(ofType: .cardReclaimed).count == 1)
    }
}
