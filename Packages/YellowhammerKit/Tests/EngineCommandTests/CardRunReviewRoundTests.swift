import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// graph-execution/run-a-card, the review's Round loop and the Attempt budget (roadmap P8.6): a reviewer's
// changes-requested is a Round of the same Attempt, sharing its round budget with the Check's (P8.5);
// exhausting it ends the Attempt `rounds-exhausted`, and the Card blocks only once the Attempt budget is
// spent too — never on the round budget alone. Nothing here asserts model quality: the fixture strings are
// carried through as given, and wiring and arithmetic are all that is checked.

private let workerCommit = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
private let reviewJudgedCommit = "c3d4e5f60718293a4b5c6d7e8f90123456789abc"
private let reviewRequestedChanges = "Satisfy DoD clause D-3: the Worktree reconciliation must record a WIP "
    + "ref on interruption.\nRemove the `print(\"here\")` left in WorktreeReconciler.swift."

@Suite("Card run, review Rounds")
struct CardRunReviewRoundTests {
    private struct Run {
        let card: CardRun
        let dispatch: SequencedDispatch
        let check: RecordingCheck
        let log: CallLog
    }

    private let red = RepositoryCheckResult.failed(output: "1 test failed", exitStatus: 2)
    private let green = RepositoryCheckResult.passed(output: "all good")

    private func makeRun(
        workerScript: [RehearsalResultFixture] = [.workerCompleted],
        reviewerScript: [RehearsalResultFixture],
        checkResults: [RepositoryCheckResult] = [.declaredNone],
        checks: [String: Check] = ["backend": .none],
        reviewRoundsMax: Int, attemptsPerCard: Int,
        resolver: RouteResolver = cardRunResolver()
    ) -> Run {
        let log = CallLog()
        let dispatch = SequencedDispatch(log: log, sequences: [.worker: workerScript, .reviewer: reviewerScript])
        let check = RecordingCheck(log: log, results: checkResults)
        let card = CardRun(
            resolver: resolver, dispatch: dispatch, check: check, checks: checks,
            reviewRoundsMax: reviewRoundsMax, attemptsPerCard: attemptsPerCard,
            resetting: RecordingAttemptResetting()
        )
        return Run(card: card, dispatch: dispatch, check: check, log: log)
    }

    @Test("Changes requested then approved: one review Round, two worker dispatches, one Attempt, Card Done")
    func changesRequestedThenApproved() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            workerScript: [.workerCompleted, .workerCompleted],
            reviewerScript: [.reviewerChangesRequested, .reviewerApproved],
            reviewRoundsMax: 2, attemptsPerCard: 3
        )

        try await run.card.run("BACK-1", in: world)

        let workers = run.dispatch.requests.passes(.worker)
        #expect(workers.count == 2)
        #expect(workers[0].instruction.cardInstruction?.payloads.roundFeedback.isEmpty == true)
        #expect(workers[1].instruction.cardInstruction?.payloads.roundFeedback.map(\.lens) == [.review])
        #expect(workers[1].route == workers[0].route)
        #expect(workers[1].attemptID == workers[0].attemptID)
        #expect(workers[1].worktreePath == workers[0].worktreePath)
        #expect(workers[1].resumeSession == "worker-session-0")

        #expect(run.dispatch.requests.passes(.reviewer).count == 2)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].rounds.map(\.lens) == [.review])
        #expect(attempts[0].result == "success")
        #expect(try world.card("BACK-1").state == .done)
    }

    @Test("The Check runs again after a review Round's rework, before the second review")
    func checkRunsAgainBeforeSecondReview() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            workerScript: [.workerCompleted, .workerCompleted],
            reviewerScript: [.reviewerChangesRequested, .reviewerApproved],
            checkResults: [green, green], checks: ["backend": .command("make test")],
            reviewRoundsMax: 2, attemptsPerCard: 3
        )

        try await run.card.run("BACK-1", in: world)

        #expect(run.log.all == [
            "dispatch architect", "dispatch worker", "check", "dispatch reviewer",
            "dispatch worker", "check", "dispatch reviewer"
        ])
    }

    @Test("The review Round records the Lens, verdict, requested changes and judged commit")
    func roundRecordsWhatWasJudged() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            workerScript: [.workerCompleted, .workerCompleted],
            reviewerScript: [.reviewerChangesRequested, .reviewerApproved],
            reviewRoundsMax: 2, attemptsPerCard: 3
        )

        try await run.card.run("BACK-1", in: world)

        let round = try #require(try world.attempts("BACK-1").first?.rounds.first)
        #expect(round.lens == .review)
        #expect(round.verdict == "changes requested")
        #expect(round.requestedChanges == reviewRequestedChanges)
        #expect(round.judgedCommit == reviewJudgedCommit)
    }

    @Test("reviewRoundsMax=1, attemptsPerCard=1, reviewer always requests changes: rounds-exhausted, blocked reviewer")
    func reviewerAlwaysRequestingChangesBlocksTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            reviewerScript: [.reviewerChangesRequested], reviewRoundsMax: 1, attemptsPerCard: 1
        )

        try await run.card.run("BACK-1", in: world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(!attempt.isOpen)
        #expect(attempt.result == "rounds-exhausted")
        #expect(attempt.rounds.map(\.lens) == [.review])
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.blockedByReviewer.rawValue)
    }

    @Test("reviewRoundsMax=1, attemptsPerCard=1, the Check always fails: rounds-exhausted, blocked by check")
    func checkAlwaysFailingBlocksTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            reviewerScript: [.reviewerApproved], checkResults: [red], checks: ["backend": .command("make test")],
            reviewRoundsMax: 1, attemptsPerCard: 1
        )

        try await run.card.run("BACK-1", in: world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(!attempt.isOpen)
        #expect(attempt.result == "rounds-exhausted")
        #expect(attempt.rounds.map(\.lens) == [.check])
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.blockedByCheck.rawValue)
        #expect(run.dispatch.requests.passes(.reviewer).isEmpty)
    }

    @Test("reviewRoundsMax=1, attemptsPerCard=2, a single Route: rounds-exhausted excludes it, and the retry Blocks")
    func roundBudgetAloneNeverBlocksTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            reviewerScript: [.reviewerChangesRequested], reviewRoundsMax: 1, attemptsPerCard: 2
        )

        try await run.card.run("BACK-1", in: world)

        let attempts = try world.attempts("BACK-1")
        #expect(attempts.count == 1)
        #expect(attempts[0].result == "rounds-exhausted")
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        // Blocked by the last Attempt's own ending — rounds-exhausted on the review Lens — not
        // `hard failure`: the Block Reason follows the final Attempt's termination (OQ58).
        #expect(card.blockReason == BlockReason.blockedByReviewer.rawValue)
        #expect(try world.journal.excludedRoutes(cardID: try #require(world.cardIDs["BACK-1"])) == [cardRunOpus])
        // Blocked because routing found no candidate, not because the Attempt budget (1 of 2) was spent.
        #expect(!(try cardRunLog(world.journal).contains(CardRunStep.attemptsExhausted.rawValue)))
    }

    @Test("attemptsPerCard=2, two Routes: a consumed seed leaves one retry, a question leaves two, both Block")
    func earlierAttemptsInTheEpochCountTowardTheBudget() async throws {
        for (seedEnding, expectedTotalAttempts) in [
            (AttemptEnding.crashedUnknown(.signaled(9)), 2),
            (AttemptEnding.question, 3)
        ] {
            let fixture = try OutboxJournalFixture()
            let world = try await makeCardRunWorld(journal: try fixture.open())
            let cardID = try #require(world.cardIDs["BACK-1"])
            let earlier = try world.journal.recordAttempt(cardID: cardID, route: cardRunOpus, runID: world.runID)
            try world.journal.endAttempt(attemptID: earlier.id, ending: seedEnding, runID: world.runID)

            let run = makeRun(
                reviewerScript: [.reviewerChangesRequested], reviewRoundsMax: 1, attemptsPerCard: 2,
                resolver: cardRunResolver(
                    table: RoutingTable(entries: [
                        RoutingEntry(kind: Kind("card")!, route: cardRunOpus, fallbacks: [cardRunFallback])
                    ])
                )
            )
            try await run.card.run("BACK-1", in: world)

            let card = try world.card("BACK-1")
            #expect(card.state == .blocked)
            #expect(card.blockReason == BlockReason.blockedByReviewer.rawValue)
            // The seed Attempt itself, plus every Attempt this run recorded: a question consumes none of
            // the budget, so it leaves the run a full extra retry the crashed seed does not.
            #expect(try world.attempts("BACK-1").count == expectedTotalAttempts)
        }
    }

    @Test("Mixed Lenses share the budget: one check Round then one review Round exhausts it, blocked by reviewer")
    func mixedLensesShareTheBudget() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let run = makeRun(
            workerScript: [.workerCompleted, .workerCompleted],
            reviewerScript: [.reviewerChangesRequested], checkResults: [red, green],
            checks: ["backend": .command("make test")], reviewRoundsMax: 2, attemptsPerCard: 1
        )

        try await run.card.run("BACK-1", in: world)

        let attempt = try #require(try world.attempts("BACK-1").first)
        #expect(attempt.rounds.map(\.lens) == [.check, .review])
        #expect(attempt.result == "rounds-exhausted")
        let card = try world.card("BACK-1")
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.blockedByReviewer.rawValue)
    }

    @Test("A review Round posts one Card comment with a Board, and nothing without one")
    func reviewRoundCommentOnlyWithABoard() async throws {
        let boardFixture = try OutboxJournalFixture()
        let boardWorld = try await makeCardRunWorld(journal: try boardFixture.open())
        try await makeRun(reviewerScript: [.reviewerChangesRequested], reviewRoundsMax: 1, attemptsPerCard: 1)
            .card.run("BACK-1", in: boardWorld)
        let bodies = try await #require(boardWorld.boards).writing.comments.map(\.body)
        #expect(bodies.count == 1)
        let body = try #require(bodies.first)
        #expect(body.contains("Round 1"))
        #expect(body.contains(reviewJudgedCommit))
        #expect(body.contains(reviewRequestedChanges))

        let noBoardFixture = try OutboxJournalFixture()
        let noBoardWorld = try await makeCardRunWorld(journal: try noBoardFixture.open(), withBoard: false)
        try await makeRun(reviewerScript: [.reviewerChangesRequested], reviewRoundsMax: 1, attemptsPerCard: 1)
            .card.run("BACK-1", in: noBoardWorld)
        #expect(try #require(try noBoardWorld.attempts("BACK-1").first).rounds.count == 1)
    }
}

@Suite("Attempt budget")
struct AttemptBudgetTests {
    @Test("Another Attempt is allowed only while fewer Attempts are consumed than the most allowed")
    func arithmetic() {
        #expect(!AttemptBudget(max: 2, consumed: 1).isExhausted)
        #expect(AttemptBudget(max: 2, consumed: 2).isExhausted)
        #expect(AttemptBudget(max: 1, consumed: 1).isExhausted)
        #expect(AttemptBudget(max: 2, consumed: 3).isExhausted)
    }
}
