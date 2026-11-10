import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// graph-execution/see-and-open-agent-sessions-in-orca, AC orca-unreachable:
// When a pass fell back to direct spawn because Orca was unreachable, its dispatch report sets
// `notShownInOrca`. The Card run journals an `agentPassNotShownInOrca` event naming the Card, Attempt,
// pass, CLI, and reason.

@Suite("Card run, passes not shown in Orca")
struct CardRunPassesNotShownInOrcaTests {
    private struct Run {
        let card: CardRun
        let dispatch: NotShownInOrcaDispatch
        let log: CallLog
    }

    private func makeRun(
        architectScript: [RehearsalResultFixture] = [.architectPlanned],
        workerScript: [RehearsalResultFixture] = [.workerCompleted],
        reviewerScript: [RehearsalResultFixture] = [.reviewerApproved],
        notShownInOrcaReason: String?
    ) -> Run {
        let log = CallLog()
        let dispatch = NotShownInOrcaDispatch(
            log: log,
            sequences: [
                .architect: architectScript,
                .worker: workerScript,
                .reviewer: reviewerScript
            ],
            scriptedNotShownInOrca: { _ in notShownInOrcaReason }
        )
        let check = RecordingCheck(log: log, results: [.declaredNone])
        let card = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: check, checks: ["backend": .none],
            reviewRoundsMax: 2, attemptsPerWorkCard: 3, passTimeoutMinutes: 60,
            resetting: RecordingAttemptResetting()
        )
        return Run(card: card, dispatch: dispatch, log: log)
    }

    @Test("When notShownInOrca is set on dispatch reports, an event is journaled for each pass")
    func notShownInOrcaJournalsEventPerPass() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let reason = "Orca was unreachable, ran unseen"
        let run = makeRun(notShownInOrcaReason: reason)

        try await run.card.run("BACK-1", in: world)

        let events = try world.journal.events(ofType: .agentPassNotShownInOrca)
        // 3 passes: architect, worker, reviewer
        #expect(events.count == 3)

        let card = try world.card("BACK-1")
        let attempt = try #require(try world.attempts("BACK-1").first)

        let passes: [RunPass] = [.architect, .worker, .reviewer]
        for (index, expectedPass) in passes.enumerated() {
            guard case .agentPassNotShownInOrca(
                let cardID, let issueID, let attemptID, let pass, let cli, let eventReason
            ) = events[index].event else {
                Issue.record("expected agentPassNotShownInOrca event for pass \(expectedPass)")
                continue
            }
            #expect(cardID == card.id)
            #expect(issueID == "BACK-1")
            #expect(attemptID == attempt.id)
            #expect(pass == expectedPass)
            #expect(!cli.isEmpty)
            #expect(eventReason == reason)
        }

        #expect(attempt.result == "success")
        #expect(card.state == .done)
    }

    @Test("When notShownInOrca is nil, no agentPassNotShownInOrca event is journaled")
    func notShownInOrcaNilJournalsNoEvent() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(notShownInOrcaReason: nil)

        try await run.card.run("BACK-1", in: world)

        let events = try world.journal.events(ofType: .agentPassNotShownInOrca)
        #expect(events.isEmpty)

        let card = try world.card("BACK-1")
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "success")
        #expect(card.state == .done)
    }
}
