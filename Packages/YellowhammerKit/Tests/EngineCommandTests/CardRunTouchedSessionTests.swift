import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC touched-session:
// When resuming a worker session during a Round, foreign turns are checked on the Dispatch Port.
// If true, an agentSessionHadForeignTurns event is recorded before dispatch and the request continues
// with the same resume session. If false, no event is recorded.

@Suite("Card run, touched worker session foreign turns")
struct CardRunTouchedSessionTests {
    private struct Run {
        let card: CardRun
        let dispatch: ForeignTurnsDispatch
        let log: CallLog
    }

    private func makeRun(
        workerScript: [RehearsalResultFixture] = [.workerCompleted, .workerCompleted],
        reviewerScript: [RehearsalResultFixture] = [.reviewerChangesRequested, .reviewerApproved],
        answerForeignTurns: Bool
    ) -> Run {
        let log = CallLog()
        let dispatch = ForeignTurnsDispatch(
            log: log,
            sequences: [.worker: workerScript, .reviewer: reviewerScript],
            scriptedForeignTurns: { _ in answerForeignTurns }
        )
        let check = RecordingCheck(log: log, results: [.declaredNone, .declaredNone])
        let card = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: check, checks: ["backend": .none],
            reviewRoundsMax: 2, attemptsPerWorkCard: 3, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        return Run(card: card, dispatch: dispatch, log: log)
    }

    @Test("When foreignTurns answers true, an event is journaled before resumed worker dispatch")
    func foreignTurnsTrueRecordsEventBeforeResume() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(answerForeignTurns: true)

        try await run.card.run("BACK-1", in: world)

        let workers = run.dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers[0].resumeSession == nil)
        #expect(workers[1].resumeSession == "worker-session-0")

        // The first worker pass (no resume) never asks about foreign turns; only the resumed worker pass asks
        let foreignTurnsCalls = run.dispatch.foreignTurnsRequests.passes(.worker)
        #expect(foreignTurnsCalls.count == 1)
        #expect(foreignTurnsCalls[0].resumeSession == "worker-session-0")

        // The journal holds exactly one event for that Card, Attempt, and Round
        let events = try world.journal.events(ofType: .agentSessionHadForeignTurns)
        #expect(events.count == 1)
        let record = try #require(events.first)
        guard case .agentSessionHadForeignTurns(let cardID, let issueID, let attemptID, let round, let cli)
            = record.event else {
            Issue.record("expected agentSessionHadForeignTurns event")
            return
        }
        let card = try world.card("BACK-1")
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(cardID == card.id)
        #expect(issueID == "BACK-1")
        #expect(attemptID == attempt.id)
        #expect(round == 2)
        #expect(cli == workers[1].route.cli)

        // The event was appended before the resumed worker dispatch
        #expect(run.log.all == [
            "dispatch architect", "dispatch worker", "check", "dispatch reviewer",
            "foreignTurns worker", "dispatch worker", "check", "dispatch reviewer"
        ])

        let allRecords = try world.journal.events()
        let eventIndex = try #require(allRecords.firstIndex(where: { $0.type == .agentSessionHadForeignTurns }))
        let resumedWorkerPromptIndex = try #require(allRecords.lastIndex(where: {
            if case .promptCaptureRequested(_, let pass, _, _, _, _, _) = $0.event {
                return pass == .worker
            }
            return false
        }))
        #expect(eventIndex < resumedWorkerPromptIndex)

        #expect(attempt.result == "success")
        #expect(card.state == .done)
    }

    @Test("When foreignTurns answers false, no event is recorded and the resume continues as usual")
    func foreignTurnsFalseRecordsNoEvent() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(answerForeignTurns: false)

        try await run.card.run("BACK-1", in: world)

        let workers = run.dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers[0].resumeSession == nil)
        #expect(workers[1].resumeSession == "worker-session-0")

        // The foreignTurns check was called for the resumed pass only
        let foreignTurnsCalls = run.dispatch.foreignTurnsRequests.passes(.worker)
        #expect(foreignTurnsCalls.count == 1)
        #expect(foreignTurnsCalls[0].resumeSession == "worker-session-0")

        // No agentSessionHadForeignTurns event was recorded
        let events = try world.journal.events(ofType: .agentSessionHadForeignTurns)
        #expect(events.isEmpty)

        let card = try world.card("BACK-1")
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "success")
        #expect(card.state == .done)
    }
}
