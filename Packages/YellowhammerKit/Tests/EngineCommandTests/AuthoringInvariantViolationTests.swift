import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// graph-execution/handle-a-block-mid-graph, P8.9: a later Card that turns out to have needed the
// blocked Card's work is an authoring-invariant violation, not an ordering failure. The architect and
// worker report it in `authoring_invariant_violation` on a `failed` result; the engine records
// `AuthoringInvariantBroken`, names the earlier hole in the same lane when there is one, and still ends
// the Attempt hard failure — budget behaviour is unchanged.

/// A Dispatch seam whose architect always plans and whose worker always fails, carrying
/// `authoring_invariant_violation`.
private struct AuthoringViolationDispatch: AgentDispatch {
    let violation: String

    func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
        switch request.pass {
        case .architect:
            return AgentDispatchReport(
                outcome: .completed(.architect(ArchitectResult(outcome: .planned(plan: "plan", affectedPaths: [])))),
                session: nil
            )
        case .worker:
            return AgentDispatchReport(
                outcome: .completed(.worker(
                    WorkerResult(outcome: .failed(reason: "cannot proceed"), authoringInvariantViolation: violation)
                )),
                session: nil
            )
        case .reviewer, .selection, .breakdown, .verifier:
            preconditionFailure("not reached: the worker fails before any other pass runs")
        }
    }
}

@Suite("Authoring-invariant violation (P8.9)")
struct AuthoringInvariantViolationTests {
    @Test("A worker failure carrying authoring_invariant_violation names the earlier Blocked Card and still hard-fails")
    func workerViolationNamesTheEarlierBlockedCard() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(
            journal: journal, cards: [("BACK-1", "backend"), ("BACK-2", "backend")], withBoard: false
        )
        // BACK-1 is already Blocked: the hole BACK-2 is about to report needing.
        _ = try journal.transitionCard(
            cardID: try world.card("BACK-1").id, to: .blocked, blockReason: .routeFailure,
            runID: world.runID, act: .build, nightID: world.context.act.night.id
        )

        let card1 = try world.card("BACK-1")
        let card2 = try world.card("BACK-2")
        let lane = RepoLane(repository: "backend", cards: [card1, card2])
        let violation = "needs the schema migration BACK-1 was supposed to add"
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: AuthoringViolationDispatch(violation: violation),
            check: RecordingCheck(log: CallLog()), checks: ["backend": .none], reviewRoundsMax: 2,
            attemptsPerWorkCard: 1, resetting: RecordingAttemptResetting()
        )

        try await run.run(
            card: card2, in: lane, context: world.context,
            readiness: CardReadiness(brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [])
        )

        // The Attempt still ends hard failure: budget behaviour is unchanged.
        let attempts = try world.attempts("BACK-2")
        #expect(attempts.map(\.result) == ["hard failure"])
        #expect(try world.card("BACK-2").state == .blocked)

        let broken = try journal.events(ofType: .authoringInvariantBroken)
        #expect(broken.count == 1)
        guard case .authoringInvariantBroken(_, let issueID, let reason) = try #require(broken.first?.event) else {
            Issue.record("expected authoringInvariantBroken")
            return
        }
        #expect(issueID == "BACK-2")
        #expect(reason.contains("authoring-invariant violation, not an ordering failure"))
        #expect(reason.contains(violation))
        #expect(reason.contains("BACK-1"))

        let steps = try cardRunLog(journal)
        #expect(steps.contains(CardRunStep.authoringInvariantViolated.rawValue))
    }

    @Test("An architect failure carrying authoring_invariant_violation is recorded the same way")
    func architectViolationIsRecorded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeCardRunWorld(journal: journal, withBoard: false)
        struct ArchitectViolationDispatch: AgentDispatch {
            func dispatch(_ request: AgentDispatchRequest) async throws -> AgentDispatchReport {
                #expect(request.pass == .architect)
                return AgentDispatchReport(
                    outcome: .completed(.architect(
                        ArchitectResult(
                            outcome: .failed(reason: "cannot plan"),
                            authoringInvariantViolation: "needs a repo BACK-0 was to add"
                        )
                    )),
                    session: nil
                )
            }
        }
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: ArchitectViolationDispatch(),
            check: RecordingCheck(log: CallLog()), checks: ["backend": .none], reviewRoundsMax: 2,
            attemptsPerWorkCard: 1, resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        let broken = try journal.events(ofType: .authoringInvariantBroken)
        #expect(broken.count == 1)
        #expect(try world.card("BACK-1").state == .blocked)
    }
}
