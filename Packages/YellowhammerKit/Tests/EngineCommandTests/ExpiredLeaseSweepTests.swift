import Darwin
import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// loop-state/reclaim-an-expired-lease (P8.10): a later Act of the same Project reclaims a dead run's
// expired Card Lease, gates on the Card's Worktree being quiescent, defensively classifies the dead
// run's open Attempt, reposts the Card from In Progress back to Ready (or Done, on a classified
// success) with a crash comment, and appends `.cardReclaimed`. Split across this file (fixtures, plain
// classification and isolation) and ExpiredLeaseSweepIntegrationTests.swift (real fencing, a real build
// Act), to keep each under the file length limit.

let reclaimEpoch = Date(timeIntervalSince1970: 1_850_000_000)
let reclaimRoute = Route(cli: "claude", model: "opus", effort: "high")!
let fortyHexCommit = String(repeating: "a", count: 40)

/// A ``RunResultReading`` fixed to one scripted `RunPassResult`, keyed by (runID, issueID, attemptID);
/// everything else answers nil, as a rehearsal Night's own binding does.
struct FixedRunResultReading: RunResultReading {
    let runID: RunID
    let issueID: String
    let attemptID: Int64
    let result: RunPassResult

    func lastPass(runID: RunID, issueID: String, attemptID: Int64) throws -> RunPassResult? {
        guard runID == self.runID, issueID == self.issueID, attemptID == self.attemptID else { return nil }
        return result
    }
}

func resultFile(pass: RunPass, json: String) -> RunPassResult {
    RunPassResult(pass: pass, data: Data(json.utf8))
}

/// A Feature → Cycle → in-progress Card, a held Worktree at a real (empty) directory, and a dead run's
/// expired Card Lease over an open Attempt on ``reclaimRoute``.
struct ReclaimFixture {
    let featureID: Int64
    let cycleID: Int64
    let cardID: Int64
    let issueID: String
    let attemptID: Int64
}

/// Builds ``ReclaimFixture``. `runID` already holds the Act-scoped Lease when this returns.
func makeReclaimFixture(
    journal: JournalStore, runID: RunID, deadRun: RunID, worktreeDirectory: URL?, now: Date = reclaimEpoch
) throws -> ReclaimFixture {
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: now) else {
        Issue.record("Could not claim the Act lease")
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let featureID = try insertReconcilerFeature(journal, issueID: "RCFEAT-\(UUID().uuidString.prefix(8))")
    try journal.recordWorktreeName(featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue))
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    let issueID = "RC-\(UUID().uuidString.prefix(8))"
    let cardID = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: issueID, repository: "backend", state: .inProgress
    )
    if let worktreeDirectory {
        try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-backend",
            path: worktreeDirectory.path, runID: runID
        )
    }
    let attempt = try journal.recordAttempt(cardID: cardID, route: reclaimRoute, runID: runID, act: .build, now: now)
    // The dead run claimed the Card's Lease, then never heartbeated past the 600s TTL.
    _ = try journal.claimCardLease(cardID: cardID, runID: deadRun, now: now.addingTimeInterval(-700))
    return ReclaimFixture(
        featureID: featureID, cycleID: cycleID, cardID: cardID, issueID: issueID, attemptID: attempt.id
    )
}

/// Appends a `.cardRunStep` event for `card`'s dead run, as its own real Act would have.
func appendPassStep(
    _ journal: JournalStore, card: ReclaimFixture, step: CardRunStep, detail: String?, runID: RunID,
    now: Date = reclaimEpoch
) throws {
    try journal.append(
        .cardRunStep(cardID: card.cardID, issueID: card.issueID, step: step, detail: detail),
        act: .build, runID: runID, nightID: nil, now: now
    )
}

/// A fresh, empty, real directory a fixture's held Worktree points at, so ``ProcessFencer`` finds it
/// (and reconciliation's `fileExists` check) rather than treating it as a ghost.
func makeReclaimWorktreeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-reclaim-wt-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Suite("ExpiredLeaseSweep (P8.10)")
struct ExpiredLeaseSweepTests {
    @Test("No result file and no failed-exit-status step: Crashed-Unknown, not excluded, Card back to Todo")
    func crashedUnknownWithNoEvidence() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let worktree = try makeReclaimWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: worktree)
        // The dead run got as far as a completed architect pass and never logged the worker.
        try appendPassStep(journal, card: card, step: .architect, detail: "completed", runID: deadRun)

        let night = try journal.openNight(
            nightStart: buildActNightStart, mode: .rehearsal, act: .build, runID: runID
        ).night

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: card.issueID, description: nil)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let outbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .build, nightID: night.id)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)

        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: night.id, clock: { reclaimEpoch },
            projection: projection
        )
        let reclaimed = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)
        #expect(reclaimed == [card.cardID])
        #expect(try journal.card(id: card.cardID).state == .todo)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        #expect(attempt.result == AttemptOutcome.crashedUnknown.rawValue)
        #expect(attempt.endedAt != nil)

        let events = try journal.events(ofType: .cardReclaimed)
        guard case .cardReclaimed(_, _, let previousRunID, let attemptID, let outcome, let routeExcluded) =
            try #require(events.first).event
        else {
            Issue.record("expected cardReclaimed")
            return
        }
        #expect(previousRunID == deadRun)
        #expect(attemptID == attempt.id)
        #expect(routeExcluded == false)
        #expect(outcome != nil)
        #expect(try journal.reclaimedCards(nightID: night.id).count == 1)

        // The comment carries the mandated wording, never "the Card continues".
        let allComments = await boards.writing.comments
        let comment = try #require(allComments.first { $0.issue.rawValue == card.issueID })
        #expect(comment.body.contains(
            "the Card is reclaimable, and no partial state was written as if it were complete"
        ))
        #expect(!comment.body.contains("the Card continues"))
        #expect(comment.body.contains(deadRun.rawValue))

        // The Card Lease is released.
        let lease = try journal.currentCardLease(cardID: card.cardID)
        #expect(lease == nil || !lease!.isHeld(at: reclaimEpoch.addingTimeInterval(1)))
    }

    @Test("A worker `failed` result file is a hard failure, Route excluded")
    func workerFailedResultFile() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: nil)
        let reader = FixedRunResultReading(
            runID: deadRun, issueID: card.issueID, attemptID: card.attemptID,
            result: resultFile(
                pass: .worker,
                json: #"{"schema":"yellowhammer.result.worker","version":1,"outcome":"failed","reason":"boom"}"#
            )
        )
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }, resultReader: reader
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        #expect(attempt.result == AttemptOutcome.hardFailure.rawValue)
        #expect(try journal.excludedRoutes(cardID: card.cardID).contains(reclaimRoute))
        #expect(try journal.card(id: card.cardID).state == .todo)
    }

    @Test("A recorded `failed(exit status 2)` step with no result file is a hard failure, Route excluded")
    func recordedExitStatusStep() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: nil)
        try appendPassStep(journal, card: card, step: .worker, detail: "failed(exit status 2)", runID: deadRun)

        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        #expect(attempt.result == AttemptOutcome.hardFailure.rawValue)
        #expect(attempt.classification == "exit status 2")
        #expect(try journal.excludedRoutes(cardID: card.cardID).contains(reclaimRoute))
    }

    @Test("A reviewer `approved` result file is a success: Card Done, known-good commit recorded")
    func reviewerApprovedResultFile() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let worktree = try makeReclaimWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: worktree)
        let reader = FixedRunResultReading(
            runID: deadRun, issueID: card.issueID, attemptID: card.attemptID,
            result: resultFile(
                pass: .reviewer,
                json: """
                {"schema":"yellowhammer.result.reviewer","version":1,"verdict":"approved",\
                "judged_commit":"\(fortyHexCommit)","summary":"lgtm"}
                """
            )
        )
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }, resultReader: reader
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        #expect(attempt.result == AttemptOutcome.success.rawValue)
        #expect(try journal.card(id: card.cardID).state == .done)
        let worktreeRecord = try #require(try journal.worktrees(featureID: card.featureID).first)
        #expect(worktreeRecord.lastKnownGoodCommit == fortyHexCommit)
    }

    @Test("An intermediate worker `completed` result file is Crashed-Unknown: it never ends the Attempt")
    func intermediateWorkerCompletedIsCrashedUnknown() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: nil)
        let reader = FixedRunResultReading(
            runID: deadRun, issueID: card.issueID, attemptID: card.attemptID,
            result: resultFile(
                pass: .worker,
                json: """
                {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
                "commit":"\(fortyHexCommit)","summary":"done"}
                """
            )
        )
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }, resultReader: reader
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        #expect(attempt.result == AttemptOutcome.crashedUnknown.rawValue)
        #expect(try journal.excludedRoutes(cardID: card.cardID).isEmpty)
    }

    @Test("A worker `question` result file is not consumed: Card back to Todo")
    func workerQuestionResultFile() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: nil)
        let reader = FixedRunResultReading(
            runID: deadRun, issueID: card.issueID, attemptID: card.attemptID,
            result: resultFile(
                pass: .worker,
                json: #"""
                {"schema":"yellowhammer.result.worker","version":1,"outcome":"question","question":"now what?"}
                """#
            )
        )
        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }, resultReader: reader
        )
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        #expect(attempt.result == AttemptOutcome.question.rawValue)
        #expect(try journal.card(id: card.cardID).state == .todo)
    }

    @Test("An unexpired lease of another run is untouched: no claim, no event, Attempt still open")
    func unexpiredLeaseUntouched() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let liveRun = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: reclaimEpoch)
        else {
            Issue.record("Could not claim the Act lease")
            return
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "LIVE-FEAT")
        try journal.recordWorktreeName(
            featureID: featureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "LIVE-1", repository: "backend", state: .inProgress
        )
        let attempt = try journal.recordAttempt(
            cardID: cardID, route: reclaimRoute, runID: runID, act: .build, now: reclaimEpoch
        )
        // Claimed 30 seconds ago: well inside the 600s TTL.
        _ = try journal.claimCardLease(cardID: cardID, runID: liveRun, now: reclaimEpoch.addingTimeInterval(-30))

        let sweep = ExpiredLeaseSweep(
            journal: journal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }
        )
        let reclaimed = try await sweep.sweep(featureID: featureID, cycleID: cycleID)

        #expect(reclaimed.isEmpty)
        #expect(try journal.events(ofType: .cardReclaimed).isEmpty)
        let lease = try #require(try journal.currentCardLease(cardID: cardID))
        #expect(lease.runID == liveRun)
        #expect(lease.isHeld(at: reclaimEpoch))
        let history = try journal.attemptHistory(cardID: cardID)
        #expect(history.attempts.first?.id == attempt.id)
        #expect(history.openAttempt != nil)
    }

    @Test("A sibling Project's Journal with an expired lease is untouched by this Project's Act")
    func siblingProjectUntouched() async throws {
        let ownFixture = try ReconcilerJournalFixture(project: "own")
        let siblingFixture = try ReconcilerJournalFixture(project: "sibling")
        let ownJournal = try ownFixture.open()
        let siblingJournal = try siblingFixture.open()
        let runID = RunID()
        let deadRun = RunID()

        // Only the sibling Journal has an expired lease; this Act only ever opens its own.
        let sibling = try makeReclaimFixture(
            journal: siblingJournal, runID: RunID(), deadRun: deadRun, worktreeDirectory: nil
        )
        let ownClaim = try ownJournal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: reclaimEpoch)
        guard case .claimed = ownClaim else {
            Issue.record("Could not claim the own Journal's Act lease")
            return
        }
        let ownFeatureID = try insertReconcilerFeature(ownJournal, issueID: "OWN-FEAT")
        try ownJournal.recordWorktreeName(
            featureID: ownFeatureID, worktreeName: WorktreeName(rawValue: buildActBranch.rawValue)
        )
        let ownCycleID = try insertReconcilerCycle(ownJournal, featureID: ownFeatureID)

        let sweep = ExpiredLeaseSweep(
            journal: ownJournal, runID: runID, act: .build, nightID: nil, clock: { reclaimEpoch }
        )
        let reclaimed = try await sweep.sweep(featureID: ownFeatureID, cycleID: ownCycleID)

        #expect(reclaimed.isEmpty)
        // The sibling's own Card and lease are exactly as its own Act left them.
        let siblingLease = try #require(try siblingJournal.currentCardLease(cardID: sibling.cardID))
        #expect(siblingLease.runID == deadRun)
        #expect(try siblingJournal.card(id: sibling.cardID).state == .inProgress)
    }
}
