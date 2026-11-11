import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC touched-session:
// When resuming a worker session during a Round, foreign turns are checked on the Dispatch Port.
// Foreign turns are journaled before dispatch and the request continues
// with the same resume session. A clean check records no event.

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
        answerForeignTurns: SessionForeignTurnsCheck,
        checkSession: (@Sendable (AgentDispatchRequest) async -> SessionForeignTurnsCheck)? = nil
    ) -> Run {
        let log = CallLog()
        let dispatch = ForeignTurnsDispatch(
            log: log,
            sequences: [.worker: workerScript, .reviewer: reviewerScript],
            scriptedForeignTurns: checkSession ?? { _ in answerForeignTurns }
        )
        let check = RecordingCheck(log: log, results: [.declaredNone, .declaredNone])
        let card = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: check, checks: ["backend": .none],
            reviewRoundsMax: 2, attemptsPerWorkCard: 3, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        return Run(card: card, dispatch: dispatch, log: log)
    }

    @Test("Foreign turns are journaled before resumed worker dispatch")
    func foreignTurnsAreRecordedBeforeResume() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(answerForeignTurns: .foreignTurns(
            userCount: 1, assistantCount: 2, firstTimestamp: "2026-11-08T10:00:00Z"
        ))

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
        guard case .agentSessionHadForeignTurns(let cardID, let issueID, let attemptID, let round, let cli,
                                                let sessionID, let userCount, let assistantCount, let firstTimestamp)
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
        #expect(sessionID == "worker-session-0")
        #expect(userCount == 1)
        #expect(assistantCount == 2)
        #expect(firstTimestamp == "2026-11-08T10:00:00Z")

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

    @Test("A clean check records no event and the resume continues as usual")
    func cleanCheckRecordsNoEvent() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(answerForeignTurns: .clean)

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
    @Test("Could not check is journaled before resume and named in the Night Summary")
    func unreadableSessionStillResumes() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(answerForeignTurns: .couldNotCheck(
            reason: "session transcript is missing or unreadable"
        ))
        try await run.card.run("BACK-1", in: world)
        let workers = run.dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers.last?.resumeSession == "worker-session-0")
        let events = try world.journal.events(ofType: .agentSessionCheckFailed)
        #expect(events.count == 1)
        let record = try #require(events.first)
        #expect(record.event.payload?["session_id"] == "worker-session-0")
        #expect(record.event.payload?["reason"] == "session transcript is missing or unreadable")
        let records = try world.journal.events()
        let checkIndex = try #require(records.firstIndex(where: { $0.type == .agentSessionCheckFailed }))
        let promptIndex = try #require(records.lastIndex(where: {
            if case .promptCaptureRequested(_, .worker, _, _, _, _, _) = $0.event { true } else { false }
        }))
        #expect(checkIndex < promptIndex)
        let night = try #require(try world.journal.currentNight())
        #expect(try NightSummary.touchedSessionLines(night: night, journal: world.journal) == [
            "`BACK-1`: could not check its session for turns Yellowhammer did not write "
                + "before Round 2; resumed as usual"
        ])
    }

    @Test("A Claude transcript with an outside turn produces an event, Summary line, and normal resume")
    func transcriptEvidenceReachesJournalAndSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appending(component: "projects/fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appending(component: "worker-session-0.jsonl")
        let content = """
        {"type":"user","uuid":"u1","entrypoint":"sdk-cli"}
        {"type":"assistant","uuid":"a1"}
        {"type":"user","uuid":"u2","entrypoint":"cli","timestamp":"2026-11-08T10:00:00Z"}
        {"type":"assistant","uuid":"a2","timestamp":"2026-11-08T10:00:01Z"}
        """
        try Data(content.utf8).write(to: transcript)
        let dispatcher = CLIAdapterDispatch(
            runsDirectory: directory, environment: ["CLAUDE_CONFIG_DIR": directory.path(percentEncoded: false)]
        )
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(answerForeignTurns: .unsupported, checkSession: { request in
            let runDirectory = dispatcher.runDirectory(for: request)
            do {
                try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
                try "a1".write(
                    to: runDirectory.appending(component: ".last-message-id"), atomically: true, encoding: .utf8
                )
            } catch {
                Issue.record("Could not write fixture marker: \(error)")
            }
            return await dispatcher.foreignTurns(before: request)
        })
        try await run.card.run("BACK-1", in: world)
        #expect(run.dispatch.requests.passes(.worker).last?.resumeSession == "worker-session-0")
        let record = try #require(try world.journal.events(ofType: .agentSessionHadForeignTurns).first)
        #expect(record.event.payload?["foreign_user_count"] == "1")
        #expect(record.event.payload?["foreign_assistant_count"] == "1")
        #expect(record.event.payload?["first_foreign_timestamp"] == "2026-11-08T10:00:00Z")
        let night = try #require(try world.journal.currentNight())
        #expect(try NightSummary.touchedSessionLines(night: night, journal: world.journal) == [
            "`BACK-1`: its session was continued outside Yellowhammer before Round 2; resumed as usual"
        ])
    }
}
