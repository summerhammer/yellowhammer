import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// End-to-end resumption (roadmap P11.2; spec: bounds/escalate-a-question-to-the-operator, second
// story): an answered Card resumes in the same build Act that reads the reply. The two steps
// `BuildAct.run` wires in order — `DeltaRead.perform()` (classifies and records the reply), then
// `WaitingOnYouReplies.apply()` (transitions the Card and acknowledges) — are exercised here exactly as
// wired, immediately followed by the same lane dispatch (``CardRun/run(_:in:)``) a build Act would run
// next: a fresh Attempt, on the Route the question's own Attempt ran on (a `question` ending never
// excludes a Route), in the Worktree the Feature already held, carrying the question and the answer. A
// remark never does any of this.

private let resumeQuestionText = "The DoD asks for a 40-hex commit, but the Worktree has no commits yet. " +
    "Should I create an empty commit first?"

private func makeRun(dispatch: any AgentDispatch, resetting: RecordingAttemptResetting? = nil) -> CardRun {
    CardRun(
        resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: CallLog()),
        checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerWorkCard: 3,
        resetting: resetting ?? RecordingAttemptResetting()
    )
}

/// What Act 1 (the worker asks a question) left behind, for a test to answer or remark against.
private struct AskedQuestion {
    let world: CardRunWorld
    let questionAttempt: AttemptRecord
    let questionCommentID: BoardObjectID
}

/// Runs Act 1 against a fresh ``CardRunWorld``.
///
/// Takes an already-opened `JournalStore` rather than opening one itself: `OutboxJournalFixture` is
/// `~Copyable`, and its `deinit` removes the Journal's directory — it must stay alive in the *caller's*
/// scope for the whole test, or the directory is gone before the rest of the test runs.
private func askQuestion(
    journal: JournalStore, resetting: RecordingAttemptResetting? = nil
) async throws -> AskedQuestion {
    let world = try await makeCardRunWorld(journal: journal)
    let dispatch = LoggingDispatch(log: CallLog(), script: [.worker: .workerQuestion])
    try await makeRun(dispatch: dispatch, resetting: resetting).run("BACK-1", in: world)

    let card = try world.card("BACK-1")
    guard card.state == .waitingOnYou, card.waitingReason == .question else {
        Issue.record("expected the Card to end Waiting on You / question, found \(card)")
        throw QuestionActSetupFailed()
    }
    let questionAttempt = try #require(try world.attempts("BACK-1").first)
    let boards = try #require(world.boards)
    let questionComment = try #require(await boards.writing.comments.first { $0.issue.rawValue == "BACK-1" })
    return AskedQuestion(world: world, questionAttempt: questionAttempt, questionCommentID: questionComment.id)
}

private struct QuestionActSetupFailed: Error {}

private func expectPreservedContext(in requests: [AgentDispatchRequest], commit: String, ref: String) throws {
    for request in requests {
        let wip = try #require(request.instruction.cardInstruction?.payloads.wip)
        #expect(wip.commit == commit)
        #expect(wip.note?.contains(ref) == true)
    }
}

@Suite("An answered Card resumes in the same build Act (P11.2)")
struct WaitingOnYouResumeTests {
    @Test("An answer resumes the Card on a fresh Attempt carrying the question and the answer")
    func answeredCardResumesInTheSameBuildAct() async throws {
        let fixture = try OutboxJournalFixture()
        let asked = try await askQuestion(journal: try fixture.open())
        let world = asked.world
        let journal = world.journal
        let featureID = world.context.feature.id
        let worktreeBefore = try #require(try journal.heldWorktree(featureID: featureID, repository: "backend"))

        let replyComment = comment(
            "reply-1", on: "BACK-1", author: humanAuthor, parent: asked.questionCommentID.rawValue, createdAt: 3_600
        )
        let reading = FakeReadingBoard([page(comments: [replyComment])])
        let read = DeltaRead(
            journal: journal, board: reading, runID: world.runID, act: .build, nightID: world.context.act.night.id
        )
        guard case .read = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        try await WaitingOnYouReplies.apply(context: world.context.act, unansweredNightsMax: 3)

        let readyCard = try world.card("BACK-1")
        #expect(readyCard.state == .todo)
        #expect(readyCard.waitingReason == nil)

        // The same build Act's lane dispatch picks the now-Ready Card up next.
        let resumeDispatch = LoggingDispatch(log: CallLog())
        try await makeRun(dispatch: resumeDispatch).run("BACK-1", in: world)

        let done = try world.card("BACK-1")
        #expect(done.state == .done)

        let history = try world.attempts("BACK-1")
        #expect(history.count == 2, "the question Attempt is preserved and a fresh one is consumed")
        #expect(history[0].result == "question")
        #expect(history[1].route == asked.questionAttempt.route, "the question Attempt's Route is never excluded")
        let cardID = try #require(world.cardIDs["BACK-1"])
        #expect(try journal.excludedRoutes(cardID: cardID).isEmpty)

        let worktreeAfter = try #require(try journal.heldWorktree(featureID: featureID, repository: "backend"))
        #expect(worktreeAfter.id == worktreeBefore.id, "the same held Worktree is reused")

        let workerRequest = try #require(resumeDispatch.requests.passes(.worker).first)
        let rendered = workerRequest.instruction.render()
        #expect(rendered.contains(resumeQuestionText))
        #expect(rendered.contains("Operator-supplied reply"))

        let boards = try #require(world.boards)
        let answerBody = WaitingOnYouAcknowledgement.answer()
        let ack = try #require(await boards.writing.comments.first { $0.body == answerBody })
        #expect(ack.issue.rawValue == "BACK-1")

        // The question Attempt's preserved work is handed over as context, not a starting tree (OQ106),
        // to every pass of the resumed run.
        let preservedRef = "refs/yellowhammer/attempts/test-branch/\(asked.questionAttempt.id)"
        try expectPreservedContext(
            in: [try #require(resumeDispatch.requests.passes(.architect).first), workerRequest],
            commit: "preserved-\(asked.questionAttempt.id)", ref: preservedRef
        )
        #expect(rendered.contains("## Work in progress"))

        // Asking reset no counter: the question Attempt keeps its ref, no Round, no Route exclusion.
        #expect(history[0].preservedRef == preservedRef)
        #expect(history[0].rounds.isEmpty)
    }

    @Test("A question Attempt that preserved nothing hands the resumed run no work in progress")
    func resumeWithNothingPreservedCarriesNoWIP() async throws {
        let fixture = try OutboxJournalFixture()
        let asked = try await askQuestion(
            journal: try fixture.open(), resetting: RecordingAttemptResetting(preserves: false)
        )
        let world = asked.world

        let replyComment = comment(
            "reply-1", on: "BACK-1", author: humanAuthor, parent: asked.questionCommentID.rawValue, createdAt: 3_600
        )
        let read = DeltaRead(
            journal: world.journal, board: FakeReadingBoard([page(comments: [replyComment])]), runID: world.runID,
            act: .build, nightID: world.context.act.night.id
        )
        guard case .read = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        try await WaitingOnYouReplies.apply(context: world.context.act, unansweredNightsMax: 3)

        let resumeDispatch = LoggingDispatch(log: CallLog())
        try await makeRun(dispatch: resumeDispatch).run("BACK-1", in: world)

        let worker = try #require(resumeDispatch.requests.passes(.worker).first)
        #expect(worker.instruction.cardInstruction?.payloads.wip == nil)
        #expect(!worker.instruction.render().contains("## Work in progress"))
    }

    @Test("A fresh run of a Card with no question Attempt carries no work in progress")
    func freshRunCarriesNoWIP() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let dispatch = LoggingDispatch(log: CallLog())

        try await makeRun(dispatch: dispatch).run("BACK-1", in: world)

        let architect = try #require(dispatch.requests.passes(.architect).first)
        #expect(architect.instruction.cardInstruction?.payloads.wip == nil)
    }

    @Test("A remark does not resume the Card")
    func remarkDoesNotResumeTheCard() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await askQuestion(journal: try fixture.open()).world
        let journal = world.journal

        // A top-level comment: not a threaded reply to anything, so it is a remark.
        let remarkComment = comment("remark-1", on: "BACK-1", author: humanAuthor, parent: nil, createdAt: 3_600)
        let reading = FakeReadingBoard([page(comments: [remarkComment])])
        let read = DeltaRead(
            journal: journal, board: reading, runID: world.runID, act: .build, nightID: world.context.act.night.id
        )
        guard case .read = try await read.perform() else {
            Issue.record("expected a read")
            return
        }
        try await WaitingOnYouReplies.apply(context: world.context.act, unansweredNightsMax: 3)

        let stillWaiting = try world.card("BACK-1")
        #expect(stillWaiting.state == .waitingOnYou)
        #expect(stillWaiting.waitingReason == .question)
        #expect(try world.attempts("BACK-1").count == 1, "no fresh Attempt was dispatched")

        let boards = try #require(world.boards)
        let ack = try #require(await boards.writing.comments.first { $0.body.hasPrefix("**Nothing changed;") })
        #expect(ack.issue.rawValue == "BACK-1")
    }
}
