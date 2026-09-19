import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// graph-execution/run-a-card, "Running a ready Card to completion" (roadmap P8.4), asserted against the
// in-memory Linear stand-in and rehearsal result fixtures: which steps ran, in what order, and what the
// Journal and the board were left holding. Nothing model-authored is asserted, and the Check's own result
// is a fake's; the Check's Round loop is in CardRunCheckRoundTests.swift.

@Suite("Card run")
struct CardRunTests {
    private func makeRun(
        log: CallLog, script: [RunPass: RehearsalResultFixture] = [:], check: RepositoryCheckResult = .declaredNone,
        checks: [String: Check] = ["backend": .none], leasePolicy: LeasePolicy = .ruled,
        during: (@Sendable (RunPass) async throws -> Void)? = nil,
        resolver: RouteResolver = cardRunResolver(), reviewRoundsMax: Int = 2, attemptsPerCard: Int = 3
    ) -> CardRun {
        CardRun(
            resolver: resolver, dispatch: LoggingDispatch(log: log, script: script, during: during),
            check: RecordingCheck(log: log, result: check), checks: checks, reviewRoundsMax: reviewRoundsMax,
            attemptsPerCard: attemptsPerCard, leasePolicy: leasePolicy
        )
    }

    @Test("A rehearsal run over the fixture result files takes a Card from Ready to Done, every step recorded")
    func rehearsalRunTakesACardFromReadyToDone() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(log: log).run("BACK-1", in: world)

        #expect(try cardRunLog(world.journal) == [
            "lease-claimed", "attempt-started", "→ In Progress", "architect", "worker", "check", "reviewer",
            "attempt ended: success", "→ Done", "lease-released"
        ])
        #expect(log.all == ["dispatch architect", "dispatch worker", "check", "dispatch reviewer"])

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.endedAt != nil)
        #expect(attempt.result == "success")
        #expect(attempt.route == cardRunOpus)
        #expect(attempt.checkDeclaredNone)
        #expect(try world.card("BACK-1").state == .done)
        #expect(try world.journal.currentCardLease(cardID: try #require(world.cardIDs["BACK-1"])) == nil)

        // The board saw the same story: the Card's issue ends in the Done workflow state.
        let boards = try #require(world.boards)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let issue = try #require(await boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState == scope.states[.done])
    }

    @Test("Architect, worker, Check, reviewer run in that order, each in the lane's Worktree")
    func passesRunInOrderInTheLanesWorktree() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), worktreePath: { "/tmp/wt-\($0)" })
        let rehearsal = RehearsalDispatch()
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: rehearsal, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3
        )

        try await run.run("BACK-1", in: world)

        #expect(rehearsal.answered.map(\.pass) == [.architect, .worker, .reviewer])
        #expect(Set(rehearsal.answered.map(\.worktreePath)) == ["/tmp/wt-backend"])
        #expect(rehearsal.answered.allSatisfy { $0.route == cardRunOpus })
        #expect(log.all == ["check"])
    }

    @Test("Changes requested with the round budget spent ends the Attempt rounds-exhausted; the Card returns to Ready")
    func changesRequestedExhaustsTheRoundBudget() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(
            log: log, script: [.reviewer: .reviewerChangesRequested], reviewRoundsMax: 1, attemptsPerCard: 2
        ).run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect", "dispatch worker", "check", "dispatch reviewer"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(!attempt.isOpen)
        #expect(attempt.result == "rounds-exhausted")
        #expect(attempt.rounds.map(\.lens) == [.review])
        #expect(try world.card("BACK-1").state == .todo)
    }

    @Test("A failed architect ends the Attempt without dispatching the worker")
    func failedArchitectSkipsTheWorker() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let log = CallLog()

        try await makeRun(log: log, script: [.architect: .architectFailed]).run("BACK-1", in: world)

        #expect(log.all == ["dispatch architect"])
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.result == "hard failure")
        #expect(try world.card("BACK-1").state == .todo)
    }
}
