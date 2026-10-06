import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// graph-execution/gate-a-card-on-the-repository-check (roadmap P8.5), the wiring: what the Card run does
// with the Check's result. The Check itself is a fake's here, so none of this asserts a repository's real
// Check — that is only ever known by running it. The runner's own mechanics are WorktreeCheckTests.swift.

private let workerCommit = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"

@Suite("Card run, Check Rounds")
struct CardRunCheckRoundTests {
    private struct Run {
        let card: CardRun
        let dispatch: LoggingDispatch
        let check: RecordingCheck
        let log: CallLog
    }

    private func makeRun(
        results: [RepositoryCheckResult], roundsMax: Int = 2, attemptsPerWorkCard: Int = 3,
        checks: [String: Check] = ["backend": .command("make test")],
        during: (@Sendable (RunPass) async throws -> Void)? = nil
    ) -> Run {
        let log = CallLog()
        let dispatch = LoggingDispatch(log: log, during: during)
        let check = RecordingCheck(log: log, results: results)
        let card = CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: check, checks: checks,
            reviewRoundsMax: roundsMax, attemptsPerWorkCard: attemptsPerWorkCard,
            resetting: RecordingAttemptResetting()
        )
        return Run(card: card, dispatch: dispatch, check: check, log: log)
    }

    private let red = RepositoryCheckResult.failed(output: "1 test failed", exitStatus: 2)
    private let green = RepositoryCheckResult.passed(output: "all good")

    @Test("Architect, worker, Check, reviewer run in that order on a green Check")
    func orderOnGreen() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(results: [green])

        try await run.card.run("BACK-1", in: world)

        #expect(run.log.all == ["dispatch architect", "dispatch worker", "check", "dispatch reviewer"])
    }

    @Test("A failed Check is a Round: the worker goes again on the same Route, Attempt and Worktree, told why")
    func failedCheckRedispatchesTheWorker() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        // A second, green Check keeps this Attempt from exhausting the round budget, so the redispatch
        // mechanics (same Route, Attempt, Worktree, and the feedback the second worker was told) are
        // visible without also exercising exhaustion, which is its own tests below.
        let run = makeRun(results: [red, green])

        try await run.card.run("BACK-1", in: world)

        let workers = run.dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers[0].instruction.cardInstruction?.payloads.roundFeedback.isEmpty == true)
        let feedback = workers[1].instruction.cardInstruction?.payloads.roundFeedback
        #expect(feedback == [
            RoundFeedback(
                round: 1, lens: .check, verdict: "failed", requestedChanges: "1 test failed",
                judgedCommit: workerCommit
            )
        ])
        #expect(workers[1].route == workers[0].route)
        #expect(workers[1].attemptID == workers[0].attemptID)
        #expect(workers[1].worktreePath == workers[0].worktreePath)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].id == workers[0].attemptID)
        let first = try #require(attempts[0].rounds.first)
        #expect(first.lens == .check)
        #expect(first.requestedChanges == "1 test failed")
        #expect(first.judgedCommit == workerCommit)
    }

    @Test("A red Check never reaches the reviewer")
    func reviewerNeverSeesRedCode() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(results: [red])

        try await run.card.run("BACK-1", in: world)

        #expect(run.dispatch.requests.passes(.reviewer).isEmpty)
    }

    @Test("Fail then pass: the reviewer runs after the green, the Card ends Done, one check Round")
    func failThenPass() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(results: [red, green])

        try await run.card.run("BACK-1", in: world)

        #expect(run.log.all == [
            "dispatch architect", "dispatch worker", "check", "dispatch worker", "check", "dispatch reviewer"
        ])
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "success")
        #expect(attempts[0].rounds.map(\.lens) == [.check])
        #expect(try world.card("BACK-1").state == .done)
    }

    @Test("Two Rounds allowed and Attempts in the budget, but a single Route: the retry finds none, Card Blocks")
    func exhaustsTwoRounds() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(results: [red], roundsMax: 2, attemptsPerWorkCard: 2)

        try await run.card.run("BACK-1", in: world)

        #expect(run.dispatch.requests.passes(.worker).count == 2)
        #expect(run.dispatch.requests.passes(.reviewer).isEmpty)
        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        let attempt = attempts[0]
        #expect(attempt.rounds.count == 2)
        #expect(!attempt.isOpen)
        #expect(attempt.result == "rounds-exhausted")
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        // Blocked by the last (and only) Attempt's own ending — rounds-exhausted on the check Lens —
        // not `route failure`: the Block Reason follows the final Attempt's termination (OQ58).
        #expect(card.blockReason == BlockReason.checkFailure.rawValue)
        // Blocked because routing found no candidate, not because the Attempt budget (1 of 2) was spent.
        let steps = try cardRunLog(world.journal)
        #expect(!steps.contains(CardRunStep.attemptsExhausted.rawValue))
        #expect(steps.contains("rounds-exhausted"))
        #expect(steps.contains("attempt ended: rounds-exhausted"))
        let exhausted = try world.journal.events(ofType: .cardRunStep).compactMap { record -> String? in
            if case .cardRunStep(_, _, .roundsExhausted, let detail) = record.event { detail } else { nil }
        }
        #expect(exhausted == ["check"])
        // The second worker was told about Round 1 only: Round 2 came after it ran.
        let retry = run.dispatch.requests.passes(.worker)[1]
        #expect(retry.instruction.cardInstruction?.payloads.roundFeedback.map(\.round) == [1])
    }

    @Test("One Round and one Attempt allowed: the Attempt ends rounds-exhausted, the spent budget blocks by Check")
    func exhaustsOneRound() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(results: [red], roundsMax: 1, attemptsPerWorkCard: 1)

        try await run.card.run("BACK-1", in: world)

        #expect(run.dispatch.requests.passes(.worker).count == 1)
        #expect(run.dispatch.requests.passes(.reviewer).isEmpty)
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.rounds.count == 1)
        #expect(!attempt.isOpen)
        #expect(attempt.result == "rounds-exhausted")
        #expect(try cardRunLog(world.journal).contains("rounds-exhausted"))
        #expect(try world.card("BACK-1").state == .blocked)
    }

    @Test("A Round already on the Attempt counts against the budget: the count is read from the Journal")
    func recordedRoundsShareTheBudget() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let cardID = try #require(world.cardIDs["BACK-1"])
        let run = makeRun(results: [red], roundsMax: 2, attemptsPerWorkCard: 2) { pass in
            guard pass == .worker else { return }
            let attempt = try #require(try world.journal.attemptHistory(cardID: cardID).openAttempt)
            if attempt.rounds.isEmpty {
                try world.journal.recordRound(
                    attemptID: attempt.id, lens: .review, verdict: "changes requested",
                    requestedChanges: "earlier", judgedCommit: nil, runID: world.runID
                )
            }
        }

        try await run.card.run("BACK-1", in: world)

        #expect(run.dispatch.requests.passes(.worker).count == 1)
        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.rounds.map(\.lens) == [.review, .check])
        #expect(try cardRunLog(world.journal).contains("rounds-exhausted"))
    }

    @Test("A failed Check posts its output and the accepted cost on the Card; a pass posts nothing")
    func commentOnFailureOnly() async throws {
        let failedFixture = try OutboxJournalFixture()
        let failedWorld = try await makeCardRunWorld(journal: try failedFixture.open())
        try await makeRun(results: [red], roundsMax: 1).card.run("BACK-1", in: failedWorld)
        let bodies = try await #require(failedWorld.boards).writing.comments.map(\.body)

        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        #expect(body.contains("1 test failed"))
        #expect(body.contains("make test"))
        #expect(body.contains("status 2"))
        #expect(body.contains("Round 1"))
        #expect(body.contains("flaky Check"))

        let greenFixture = try OutboxJournalFixture()
        let greenWorld = try await makeCardRunWorld(journal: try greenFixture.open())
        try await makeRun(results: [green]).card.run("BACK-1", in: greenWorld)
        #expect(try await #require(greenWorld.boards).writing.comments.isEmpty)
    }

    @Test("Without a Board the failed Check is recorded and nothing is posted")
    func noBoardNoComment() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open(), withBoard: false)
        let run = makeRun(results: [red], roundsMax: 1)

        try await run.card.run("BACK-1", in: world)

        #expect(try #require(try world.attempts("BACK-1").first).rounds.count == 1)
    }

    @Test("The Check's output goes to the checkRan event for a pass, a fail and a declared none")
    func checkRanIsAppendedForEveryRun() async throws {
        struct Case {
            let answer: RepositoryCheckResult
            let kind: CheckRunResult
            let status: Int32?
            let output: String?
            let check: Check
        }
        let cases = [
            Case(answer: green, kind: .passed, status: 0, output: "all good", check: .command("make test")),
            Case(answer: red, kind: .failed, status: 2, output: "1 test failed", check: .command("make test")),
            Case(answer: .declaredNone, kind: .declaredNone, status: nil, output: nil, check: .none)
        ]
        for testCase in cases {
            let fixture = try OutboxJournalFixture()
            let world = try await makeCardRunWorld(journal: try fixture.open())
            try await makeRun(results: [testCase.answer], roundsMax: 1, checks: ["backend": testCase.check]).card
                .run("BACK-1", in: world)

            let ran = try world.journal.events(ofType: .checkRan).map(\.event)
            let attemptID = try #require(try world.attempts("BACK-1").first).id
            #expect(ran == [.checkRan(
                cardID: try #require(world.cardIDs["BACK-1"]), issueID: "BACK-1", attemptID: attemptID,
                result: testCase.kind, exitStatus: testCase.status, output: testCase.output
            )])
            // The step names the outcome's kind, never its output.
            let stepDetails = try world.journal.events(ofType: .cardRunStep).compactMap { record -> String? in
                if case .cardRunStep(_, _, .check, let detail) = record.event { detail } else { nil }
            }
            #expect(stepDetails.count == 1)
            #expect(stepDetails.allSatisfy { !$0.contains("1 test failed") && !$0.contains("all good") })
        }
    }

    @Test("check = none: nothing is spawned by the runner, and the Attempt records the declaration")
    func declaredNoneSpawnsNothing() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(
            journal: try fixture.open(), worktreePath: { _ in "/nonexistent/yh-\(UUID().uuidString)" }
        )
        let log = CallLog()
        let run = CardRun(
            resolver: cardRunResolver(), dispatch: LoggingDispatch(log: log), check: WorktreeCheck(),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
            resetting: RecordingAttemptResetting()
        )

        try await run.run("BACK-1", in: world)

        // A missing Worktree would have thrown had the runner tried to spawn anything.
        #expect(try #require(try world.attempts("BACK-1").first).checkDeclaredNone)
        #expect(try world.card("BACK-1").state == .done)
    }
}

@Suite("Round budget and Check comment")
struct RoundBudgetTests {
    @Test("Another Round is allowed only while fewer Rounds are recorded than the most allowed")
    func arithmetic() {
        #expect(RoundBudget(max: 2, recorded: 1).allowsAnotherRound)
        #expect(!RoundBudget(max: 2, recorded: 2).allowsAnotherRound)
        #expect(!RoundBudget(max: 1, recorded: 1).allowsAnotherRound)
        #expect(!RoundBudget(max: 2, recorded: 3).allowsAnotherRound)
    }

    @Test("The Check comment names the Round, command and status, fences the output, and states the cost")
    func commentBody() {
        let body = CardRun.checkRoundComment(round: 2, command: "make test", exitStatus: 3, output: "boom ``` boom")

        #expect(body.contains("Round 2"))
        #expect(body.contains("`make test` exited with status 3"))
        #expect(body.contains("````\nboom ``` boom\n````"))
        #expect(body.contains("risk R6"))
    }

    @Test("The Check comment keeps only the last 8 KiB of a long output")
    func commentTail() {
        let output = String(repeating: "a", count: 10_000) + "TAIL"

        let body = CardRun.checkRoundComment(round: 1, command: "c", exitStatus: 1, output: output)

        #expect(body.contains("TAIL"))
        #expect(body.contains("1812 earlier bytes of output omitted"))
        #expect(!body.contains(String(repeating: "a", count: 8_200)))
    }
}
