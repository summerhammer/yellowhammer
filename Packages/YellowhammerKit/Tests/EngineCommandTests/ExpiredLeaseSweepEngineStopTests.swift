import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Testing

// The Expired Lease Sweep's OQ92 wording: a dead run that recorded `.leaseLeftToExpire` before dying is
// worded "stopped by the engine", never "crash", classification unchanged. Split out of
// ExpiredLeaseSweepTests.swift (shared fixtures there) to keep each file under the length limit.

@Suite("ExpiredLeaseSweep: the engine stopped the dead run (OQ92)")
struct ExpiredLeaseSweepEngineStopTests {
    @Test("A dead run that recorded lease-left-to-expire: the comment says stopped by the engine, not crashed")
    func engineStoppedCommentWording() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let worktree = try makeReclaimWorktreeDirectory()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: worktree)
        try appendPassStep(journal, card: card, step: .worker, detail: "completed", runID: deadRun)
        try appendPassStep(journal, card: card, step: .leaseLeftToExpire, detail: "heartbeat failed", runID: deadRun)

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
        _ = try await sweep.sweep(featureID: card.featureID, cycleID: card.cycleID)

        let history = try journal.attemptHistory(cardID: card.cardID)
        let attempt = try #require(history.attempts.first)
        // Classification is unchanged by OQ92: still Crashed-Unknown, still not excluded.
        #expect(attempt.result == AttemptOutcome.crashedUnknown.rawValue)
        #expect(attempt.classification?.hasPrefix("stopped by the engine: ") == true)
        #expect(try journal.excludedRoutes(cardID: card.cardID).isEmpty)

        let allComments = await boards.writing.comments
        let comment = try #require(allComments.first { $0.issue.rawValue == card.issueID })
        #expect(comment.body.contains("stopped by the engine: heartbeat failed"))
        #expect(!comment.body.contains("never released it"))
        #expect(comment.body.contains(
            "the Card is reclaimable, and no partial state was written as if it were complete"
        ))
    }

    @Test("A failed-exit-status step still wins over a recorded lease-left-to-expire: still a hard failure")
    func exitStatusStepStillWinsOverEngineStop() async throws {
        let fixture = try ReconcilerJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        let deadRun = RunID()
        let card = try makeReclaimFixture(journal: journal, runID: runID, deadRun: deadRun, worktreeDirectory: nil)
        try appendPassStep(journal, card: card, step: .worker, detail: "failed(exit status 2)", runID: deadRun)
        try appendPassStep(journal, card: card, step: .leaseLeftToExpire, detail: "heartbeat failed", runID: deadRun)

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
}
