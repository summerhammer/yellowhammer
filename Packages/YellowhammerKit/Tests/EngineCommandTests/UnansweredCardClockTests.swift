import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// The unanswered-Nights bound end to end (roadmap P11.4; spec: bounds/bound-unanswered-nights):
// ``UnansweredCardClock`` advancing the Journal's clock (``JournalStore/advanceCardUnansweredClocks``)
// and auto-Blocking every Card it finds past the bound (``CardAutoBlock/specific``), through the same
// ``ReplyWorld`` fixture WaitingOnYouAnswerTests.swift and WaitingOnYouBankedReplyTests.swift use.
// `unansweredNightsMax = 1` throughout, so a Card's second qualifying Night exceeds the bound.

/// One Card, in an open Cycle, assigned to the Operator on its first (real) transition into Waiting on
/// You, question route, ready for ``UnansweredCardClockTests`` to advance the clock over — split out of
/// the test that builds it to keep that function within the length limit.
private struct AssignedQuestionCardWorld {
    let journal: JournalStore
    let runID: RunID
    let cardID: Int64
    let cycleID: Int64
    let night1: NightRecord
    let boards: NightCardTestBoards
    let scope: BoardStateScope
    let operatorID = BoardObjectID(rawValue: "operator-1")

    static func make(_ journal: JournalStore) async throws -> AssignedQuestionCardWorld {
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
        let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
        let cardID = try insertReconcilerCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
        )
        let night1 = try journal.openNight(
            nightStart: NightStart(rawValue: "2026-09-20")!, mode: .rehearsal, act: .build, runID: runID
        ).night

        let boards = try await makeBuildActBoards()
        await boards.writing.seed(issue: "BACK-1", description: nil)
        let scope = try await BoardStateScope.resolve(using: boards.provisioning)
        let world = AssignedQuestionCardWorld(
            journal: journal, runID: runID, cardID: cardID, cycleID: cycleID, night1: night1, boards: boards,
            scope: scope
        )

        let outbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .build, nightID: night1.id)
        let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        _ = try journal.claimCardLease(cardID: cardID, runID: runID)
        _ = try await projection.transition(
            card: try journal.card(id: cardID), to: .waitingOnYou(.question, operator: world.operatorID)
        )
        _ = try journal.releaseCardLease(cardID: cardID, runID: runID)

        let attemptID = try journal.recordAttempt(
            cardID: cardID, route: cardRunOpus, runID: runID, act: .build, nightID: night1.id
        ).id
        _ = try journal.recordCardQuestion(
            cardID: cardID, attemptID: attemptID, question: "Which endpoint?", commentClientID: "CLIENT-1",
            nightID: night1.id, act: .build, runID: runID
        )
        return world
    }

    func context(night: NightRecord) -> ActContext {
        let actBoard = ActBoard(
            reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning
        )
        let outbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .build, nightID: night.id)
        return ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, board: actBoard, mainlines: ResolvedMainlines()
        )
    }

    func openNight(_ start: NightStart) throws -> NightRecord {
        try journal.openNight(nightStart: start, mode: .rehearsal, act: .build, runID: runID).night
    }
}

@Suite("The unanswered-Nights bound end to end (P11.4)")
struct UnansweredCardClockTests {
    @Test("Question route: the second qualifying Night auto-Blocks `reply overdue`, keeping the question and assignee")
    func questionRouteBlocksUnanswered() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await AssignedQuestionCardWorld.make(journal)

        // Night 1 (the opening Night) never counts.
        try await UnansweredCardClock.run(
            cycleIDs: [world.cycleID], unansweredNightsMax: 1, context: world.context(night: world.night1)
        )
        #expect(try journal.card(id: world.cardID).unansweredNights == 0)

        // Night 2: counts 1, still under the bound of 1.
        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!)
        try await UnansweredCardClock.run(
            cycleIDs: [world.cycleID], unansweredNightsMax: 1, context: world.context(night: night2)
        )
        #expect(try journal.card(id: world.cardID).state == .waitingOnYou)
        #expect(try journal.card(id: world.cardID).unansweredNights == 1)

        // Night 3: exceeds the bound — auto-Blocked `reply overdue`.
        let night3 = try world.openNight(NightStart(rawValue: "2026-09-22")!)
        try await UnansweredCardClock.run(
            cycleIDs: [world.cycleID], unansweredNightsMax: 1, context: world.context(night: night3)
        )

        let card = try journal.card(id: world.cardID)
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.replyOverdue.rawValue)
        #expect(try journal.latestCardQuestion(cardID: world.cardID) != nil, "the question record survives")
        #expect(try journal.events(ofType: .cardUnansweredBoundFired).count == 1)

        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.assignee == world.operatorID, "auto-Block never clears the assignee")
        #expect(issue.workflowState == world.scope.states[.blocked])
    }

    @Test("Divergence route: the bound fires `decision overdue`, never `reply overdue`")
    func divergenceRouteBlocksUndecided() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .divergence)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!)
        let context2 = world.context(night: night2, reading: FakeReadingBoard([]))
        try await UnansweredCardClock.run(cycleIDs: [world.cycleID], unansweredNightsMax: 1, context: context2)

        let night3 = try world.openNight(NightStart(rawValue: "2026-09-22")!)
        let context3 = world.context(night: night3, reading: FakeReadingBoard([]))
        try await UnansweredCardClock.run(cycleIDs: [world.cycleID], unansweredNightsMax: 1, context: context3)

        let card = try world.card()
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.decisionOverdue.rawValue)
    }

    @Test("A Partial Landing's unanswered Card spends its Nights through the author Act and auto-Blocks")
    func partialLandingCardAdvancesThroughAuthorAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        // Landed, never archived: Verification returned the Feature, and no build Act works it again.
        try world.markCycleLanded()
        #expect(try journal.landedCycleIDsWithWaitingOnYouCards() == [world.cycleID])

        for nightStart in ["2026-09-21", "2026-09-22"] {
            let night = try world.openNight(NightStart(rawValue: nightStart)!)
            let context = world.context(night: night, reading: FakeReadingBoard([]), act: .author)
            try await UnansweredCardClock.run(
                cycleIDs: try journal.landedCycleIDsWithWaitingOnYouCards(), unansweredNightsMax: 1, context: context
            )
        }

        let card = try world.card()
        #expect(card.state == .blocked)
        #expect(card.blockReason == BlockReason.replyOverdue.rawValue)
        #expect(try journal.events(ofType: .cardUnansweredBoundFired).count == 1)
    }

    @Test("A banked reply's Card never advances through the author Act's post-landing step")
    func bankedReplyNeverAdvancesThroughAuthorAct() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        try world.markCycleLanded()
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        let context = world.context(night: world.night, reading: reading, act: .author)

        try await PostLandingReplies.run(context: context, unansweredNightsMax: 1)
        #expect(try journal.bankedCardReplies(cardID: world.cardID).count == 1)

        let landedCycleIDs = try journal.landedCycleIDsWithWaitingOnYouCards()
        try await UnansweredCardClock.run(cycleIDs: landedCycleIDs, unansweredNightsMax: 1, context: context)

        #expect(try world.card().unansweredNights == 0)
        #expect(try world.card().state == .waitingOnYou)
    }

    @Test("A degraded Delta Read must never be charged as silence: a real build Act does not advance the clock")
    func degradedReadDoesNotAdvanceTheClock() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)

        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!)
        let degraded = FakeReadingBoard([.failure(.rateLimited(retryAfter: nil, budget: nil))])
        let actBoard = ActBoard(
            reading: degraded, writing: world.boards.writing, provisioning: world.boards.provisioning
        )
        let outbox = Outbox(
            journal: journal, board: world.boards.writing, runID: world.runID, act: .build, nightID: night2.id
        )
        let context = ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: world.runID, journal: journal, night: night2,
            outbox: outbox, board: actBoard, mainlines: ResolvedMainlines()
        )

        let buildAct = BuildAct(cardRunner: RecordingCardRunner(), unansweredNightsMax: 1)
        try await buildAct.run(context)

        #expect(try world.card().unansweredNights == 0, "an unread answer must never be charged as silence")
        #expect(try world.card().state == .waitingOnYou)
    }
}
