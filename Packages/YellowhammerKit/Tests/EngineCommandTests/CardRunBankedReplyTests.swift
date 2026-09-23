import Domain
@testable import Engine
import Foundation
import Journal
import Testing

// roadmap P11.5 (spec: feature-authoring/author-the-cycle-and-card-dag, second story): the banked-reply
// payload at the adopting dispatch. A worker's earlier question is recorded, one reply to it is banked
// (roadmap P11.3) and one is not; the next dispatch's instruction keeps the question (via the unbanked
// reply) and carries the banked reply in its own section, dated and stamped with the Night it was
// banked and the mainline commit as of then, never twice.

private let bankedQuestionText = "The DoD asks for a 40-hex commit, but the Worktree has no commits yet. " +
    "Should I create an empty commit first?"

@Suite("The banked-reply payload at the adopting dispatch (P11.5)")
struct CardRunBankedReplyTests {
    private func makeRun(log: CallLog, dispatch: any AgentDispatch) -> CardRun {
        CardRun(
            resolver: cardRunResolver(), dispatch: dispatch, check: RecordingCheck(log: log),
            checks: ["backend": .none], reviewRoundsMax: 2, attemptsPerCard: 3,
            resetting: RecordingAttemptResetting(log: log)
        )
    }

    /// Records one banked and one kept reply to `question`, and banks the first with `mainlineCommit`.
    private func recordBankedAndKeptReplies(
        cardID: Int64, question: CardQuestionRecord, mainlineCommit: String, world: CardRunWorld
    ) throws {
        let journal = world.journal
        let bankedReply = try journal.recordCardReply(
            CardReplyDraft(
                cardID: cardID, issueID: "BACK-1", questionID: question.id, commentID: "reply-banked",
                body: "Backfill existing rows too.", authorName: "Operator", disposition: .answer,
                commentedAt: Date()
            ),
            nightID: world.context.act.night.id
        )
        _ = try journal.recordCardReply(
            CardReplyDraft(
                cardID: cardID, issueID: "BACK-1", questionID: question.id, commentID: "reply-kept",
                body: "Actually, going forward only.", authorName: "Operator", disposition: .answer,
                commentedAt: Date()
            ),
            nightID: world.context.act.night.id
        )
        try journal.bankCardReply(
            id: bankedReply.id, stamps: [MainlineStamp(repository: "backend", commit: mainlineCommit)],
            nightID: world.context.act.night.id
        )
    }

    @Test("""
        The next dispatch's worker instruction carries the banked reply (dated, with its Night and \
        mainline commit) in its own section, and keeps the question via the reply that was not banked
        """)
    func instructionCarriesBankedReplyAndKeepsTheQuestion() async throws {
        let fixture = try OutboxJournalFixture()
        let world = try await makeCardRunWorld(journal: try fixture.open())
        let journal = world.journal
        let cardID = try #require(world.cardIDs["BACK-1"])

        // Night 1: the worker asks a question; the Card moves to Waiting on You / question.
        let log1 = CallLog()
        try await makeRun(log: log1, dispatch: LoggingDispatch(log: log1, script: [.worker: .workerQuestion]))
            .run("BACK-1", in: world)

        let question = try #require(try journal.latestCardQuestion(cardID: cardID))
        #expect(question.question == bankedQuestionText)

        // Two replies: one is banked (the Feature that put this Card in Waiting on You has landed), one
        // is not — so the question is still carried, via the reply that was never banked.
        let mainlineCommit = String(repeating: "d", count: 40)
        try recordBankedAndKeptReplies(
            cardID: cardID, question: question, mainlineCommit: mainlineCommit, world: world
        )

        // Night 2 (same World's Act here, for simplicity): the Card is dispatched again and completes.
        let log2 = CallLog()
        let dispatch2 = LoggingDispatch(log: log2, script: [.worker: .workerCompleted, .reviewer: .reviewerApproved])
        try await makeRun(log: log2, dispatch: dispatch2).run("BACK-1", in: world)

        #expect(try world.card("BACK-1").state == .done)

        let workerRequest = try #require(dispatch2.requests.passes(.worker).first)
        guard case .card(let instruction) = workerRequest.instruction else {
            Issue.record("expected a card instruction")
            return
        }
        let rendered = instruction.render()

        // The banked reply's own section: dated, carrying the Night it was banked and the mainline
        // commit as of then, and its body — never the unbanked one.
        #expect(rendered.contains("## Banked replies"))
        #expect(rendered.contains("Backfill existing rows too."))
        #expect(rendered.contains(mainlineCommit))
        #expect(rendered.contains(world.context.act.night.nightStart.rawValue))

        // The question is still carried, via the reply that was not banked.
        #expect(rendered.contains("## Your earlier question, answered"))
        #expect(rendered.contains(bankedQuestionText))
        #expect(rendered.contains("Actually, going forward only."))
        // The banked reply's body never appears twice, inside the kept question's own replies.
        let answeredSection = try #require(
            rendered.components(separatedBy: "## Your earlier question, answered").last
        )
        let bankedSectionRange = answeredSection.range(of: "## Banked replies")
        let beforeBankedSection = bankedSectionRange
            .map { String(answeredSection[..<$0.lowerBound]) } ?? answeredSection
        #expect(!beforeBankedSection.contains("Backfill existing rows too."))
    }
}
