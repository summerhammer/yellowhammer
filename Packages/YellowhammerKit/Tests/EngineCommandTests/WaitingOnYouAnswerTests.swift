import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// Answer detection and resumption (roadmap P11.2; spec: bounds/escalate-a-question-to-the-operator,
// second story; board-projection/read-board-changes-by-delta, G-8): classifying a human comment on a
// Card in Waiting on You (answer / remark / divergence), recording it inside the Delta Read's
// reconciliation, and applying it (Card transition + acknowledgement) through the Journal-driven apply
// step (``WaitingOnYouReplies``), independent of the Delta Read that recorded it.

// Close to the real wall clock, not `outboxEpoch`: `JournalStore.claimCardLease`/`releaseCardLease`
// (called by production ``WaitingOnYouReplies``) default their own `now` to `Date()`, so a
// `ManualClock` seeded far from it would read a freshly claimed Lease as already expired the moment
// `Outbox.deliver` revalidates it against this clock.
let replyEpoch = Date()
let replyNightStart = NightStart(rawValue: "2026-09-20")!
let replyQuestionText = "Which endpoint should this call?"

/// A Journal with one Feature/Cycle/Card ("BACK-1", `backend`) in Waiting on You, a held Act Lease, one
/// open Night, and a Board bound through a real Outbox — for `.question`, the question comment is
/// posted through that Outbox exactly as ``CardRun`` does, so a reply's `parent` can name the board's
/// own comment id (matcher path (a): the Outbox entry's `result`), not merely the client id.
struct ReplyWorld {
    let journal: JournalStore
    let runID: RunID
    let cardID: Int64
    let questionID: Int64?
    /// The question comment's id as the board assigned it; nil for `.divergence`.
    let questionCommentBoardID: BoardObjectID?
    let night: NightRecord
    let boards: NightCardTestBoards
    let clock: ManualClock

    func card() throws -> CardRecord { try journal.card(id: cardID) }

    /// Opens a further Night on the same Act Lease, so a remark's Silence countdown can be tested
    /// across a real Night gap.
    func openNight(_ start: NightStart) throws -> NightRecord {
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: clock.read())
        else { throw JournalError.actLeaseLost(runID: runID, holder: nil) }
        return try journal.openNight(nightStart: start, mode: .rehearsal, act: .build, runID: runID, now: clock.read())
            .night
    }

    func context(night: NightRecord, reading: FakeReadingBoard) -> ActContext {
        let outbox = Outbox(
            journal: journal, board: boards.writing, runID: runID, act: .build, nightID: night.id, clock: clock.read
        )
        let actBoard = ActBoard(reading: reading, writing: boards.writing, provisioning: boards.provisioning)
        return ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal, night: night,
            outbox: outbox, board: actBoard
        )
    }

    func deltaRead(night: NightRecord, reading: FakeReadingBoard) -> DeltaRead {
        DeltaRead(journal: journal, board: reading, runID: runID, act: .build, nightID: night.id, clock: clock.read)
    }
}

func makeReplyWorld(journal: JournalStore, waitingReason: WaitingReason) async throws -> ReplyWorld {
    let clock = ManualClock(replyEpoch)
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal, now: clock.read())
    else { throw JournalError.actLeaseLost(runID: runID, holder: nil) }

    let featureID = try insertReconcilerFeature(journal, issueID: "FEAT-1")
    try journal.recordFeatureBranch(featureID: featureID, branch: buildActBranch)
    let cycleID = try insertReconcilerCycle(journal, featureID: featureID)
    let cardID = try insertReconcilerCard(
        journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", state: .todo
    )
    let night = try journal.openNight(
        nightStart: replyNightStart, mode: .rehearsal, act: .build, runID: runID, now: clock.read()
    ).night

    let boards = try await makeBuildActBoards()
    await boards.writing.seed(issue: "BACK-1", description: nil)
    let outbox = Outbox(
        journal: journal, board: boards.writing, runID: runID, act: .build, nightID: night.id, clock: clock.read
    )

    var questionID: Int64?
    var questionCommentBoardID: BoardObjectID?
    if waitingReason == .question {
        let posted = try await postQuestion(runID: runID, cardID: cardID, night: night, outbox: outbox, clock: clock)
        questionID = posted.questionID
        questionCommentBoardID = posted.questionCommentBoardID
    }
    _ = try journal.transitionCard(
        cardID: cardID, to: .waitingOnYou, waitingReason: waitingReason, runID: runID, act: .build,
        nightID: night.id, now: clock.read()
    )

    return ReplyWorld(
        journal: journal, runID: runID, cardID: cardID, questionID: questionID,
        questionCommentBoardID: questionCommentBoardID, night: night, boards: boards, clock: clock
    )
}

/// Records an Attempt and its question, posting the question comment the way `CardRun.concludeAsked`
/// does (through the Outbox, under the Card's Lease) — split out of `makeReplyWorld` to keep it within
/// the function-body length limit. Reads the Journal from `outbox.journal` to stay within the
/// parameter-count limit too.
private func postQuestion(
    runID: RunID, cardID: Int64, night: NightRecord, outbox: Outbox, clock: ManualClock
) async throws -> (questionID: Int64, questionCommentBoardID: BoardObjectID) {
    let journal = outbox.journal
    let attempt = try journal.recordAttempt(
        cardID: cardID, route: cardRunOpus, runID: runID, act: .build, nightID: night.id, now: clock.read()
    ).id
    let key = "question:BACK-1:\(attempt)"
    let commentClientID = outbox.clientID(for: key).uuidString
    _ = try journal.claimCardLease(cardID: cardID, runID: runID, now: clock.read())
    let delivery = try await outbox.post(
        OutboxWrite(
            key: key, write: .createComment(issue: BoardObjectID(rawValue: "BACK-1"), body: "the question"),
            cardID: cardID
        )
    )
    _ = try journal.releaseCardLease(cardID: cardID, runID: runID)
    guard case .applied(let boardID?) = delivery.outcome else {
        throw ReplyWorldSetupFailed()
    }
    let question = try journal.recordCardQuestion(
        cardID: cardID, attemptID: attempt, question: replyQuestionText, commentClientID: commentClientID,
        nightID: night.id, act: .build, runID: runID, now: clock.read()
    )
    return (question.id, boardID)
}

struct ReplyWorldSetupFailed: Error {}

@Suite("Answer detection and resumption (P11.2)")
struct WaitingOnYouAnswerTests {
    @Test("A threaded reply to the latest question comment is recorded an answer and resumes the Card")
    func threadedReplyToLatestQuestionIsAnAnswer() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        let boardID = try #require(world.questionCommentBoardID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: boardID.rawValue)
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        guard case .read(let report) = try await world.deltaRead(night: world.night, reading: reading).perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.waitingOnYouReplies.map(\.disposition) == [.answer])
        #expect(report.waitingOnYouReplies[0].commentID == "reply-1")

        let context = world.context(night: world.night, reading: reading)
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        try await assertCardResumedOnBoard(world: world, questionCommentBoardID: boardID)
        #expect(try journal.unappliedCardReplies().isEmpty)
    }

    /// Matcher path (b): Linear creates the question comment under the Outbox client id, lowercased, and
    /// the Journal stores that id uppercased — a reply naming it is an answer without the Outbox result.
    @Test("A threaded reply naming the question's client id, in any case, is an answer")
    func threadedReplyToClientIDIsAnAnswer() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)
        let clientID = try #require(try journal.latestCardQuestion(cardID: world.cardID)?.commentClientID)

        let replyComment = comment("reply-1", on: "BACK-1", author: humanAuthor, parent: clientID.lowercased())
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        guard case .read(let report) = try await world.deltaRead(night: world.night, reading: reading).perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.waitingOnYouReplies.map(\.disposition) == [.answer])
    }

    /// The Journal and board assertions common to an answer resuming the Card, split out to keep the
    /// test that calls it within the function-body length limit.
    private func assertCardResumedOnBoard(world: ReplyWorld, questionCommentBoardID: BoardObjectID) async throws {
        let card = try world.card()
        #expect(card.state == .todo)
        #expect(card.waitingReason == nil)

        let scope = try await BoardStateScope.resolve(using: world.boards.provisioning)
        let issue = try #require(await world.boards.writing.issue(BoardObjectID(rawValue: "BACK-1")))
        #expect(issue.workflowState == scope.states[.todo])
        #expect(card.boardStateVersion == card.stateVersion)

        let ack = try #require(await world.boards.writing.comments.first { $0.id != questionCommentBoardID })
        #expect(ack.body == WaitingOnYouAcknowledgement.answer())
        #expect(ack.issue.rawValue == "BACK-1")
    }

    @Test("A top-level comment, and a reply to another comment, are both remarks that leave the Card untouched")
    func nonThreadedOrMisdirectedRepliesAreRemarks() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .question)

        // One Night elapses between the question and the remark: with unansweredNightsMax 3, 1 elapsed
        // Night leaves 2 remaining.
        let night2 = try world.openNight(NightStart(rawValue: "2026-09-21")!)

        let topLevel = comment("remark-1", on: "BACK-1", author: humanAuthor, parent: nil, createdAt: 3_600)
        let misdirected = comment(
            "remark-2", on: "BACK-1", author: humanAuthor, parent: "some-unrelated-comment", createdAt: 3_700
        )
        let reading = FakeReadingBoard([page(comments: [topLevel, misdirected])])
        guard case .read(let report) = try await world.deltaRead(night: night2, reading: reading).perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.waitingOnYouReplies.map(\.disposition) == [.remark, .remark])

        let context = world.context(night: night2, reading: reading)
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        let card = try world.card()
        #expect(card.state == .waitingOnYou)
        #expect(card.waitingReason == .question)

        let expectedBody = WaitingOnYouAcknowledgement.remark(question: replyQuestionText, nightsRemaining: 2)
        let acks = await world.boards.writing.comments.filter { $0.body == expectedBody }
        #expect(acks.count == 2, "one acknowledgement per human comment")
        #expect(acks.allSatisfy { $0.issue.rawValue == "BACK-1" })

        #expect(try journal.unappliedCardReplies().isEmpty)
    }

    @Test("Any comment on a Card in Waiting on You for a Divergence notice is a Divergence reply")
    func anyCommentOnADivergenceCardIsADivergenceReply() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let world = try await makeReplyWorld(journal: journal, waitingReason: .divergence)

        let threaded = comment(
            "reply-1", on: "BACK-1", author: humanAuthor, parent: "anything-at-all", createdAt: 3_600
        )
        let reading = FakeReadingBoard([page(comments: [threaded])])
        guard case .read(let report) = try await world.deltaRead(night: world.night, reading: reading).perform() else {
            Issue.record("expected a read")
            return
        }
        #expect(report.waitingOnYouReplies.map(\.disposition) == [.divergence])
        #expect(report.waitingOnYouReplies[0].questionID == nil)

        let context = world.context(night: world.night, reading: reading)
        try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)

        let card = try world.card()
        #expect(card.state == .waitingOnYou, "nothing runs, and the Card is untouched")
        #expect(card.waitingReason == .divergence)

        let ack = try #require(
            await world.boards.writing.comments.first { $0.body == WaitingOnYouAcknowledgement.divergence() }
        )
        #expect(ack.issue.rawValue == "BACK-1")

        #expect(try journal.unappliedCardReplies().isEmpty)
    }
}
