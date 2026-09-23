import Domain
import Foundation
import Journal

/// The board-side half of a classified Waiting on You reply (roadmap P11.2, P11.3), Journal-driven so
/// it is crash-safe independently of the Delta Read that recorded it: every reply
/// ``JournalStore/unappliedCardReplies()`` names is processed here, in id order, and marked applied only
/// once its transition (an `answer` only) and its acknowledgement (every disposition) both returned
/// without throwing. An Act killed between the two completes on the next build Act's own call; a
/// resumed run posts no duplicate acknowledgement, since the Outbox key is idempotent on the comment id.
///
/// An `answer` whose Card's Cycle has already landed (roadmap P11.3) is banked instead of dispatched —
/// lanes do not reopen — so this Act runs after landing too, from a step ``AuthorAct`` performs once no
/// Delta Read is otherwise in the build Act's own path (``PostLandingReplies``).
enum WaitingOnYouReplies {
    /// Applies every unapplied reply. Never throws for one reply's own board refusal or a Card Lease
    /// held by another run — those replies are simply left unapplied — but an unexpected Journal fault
    /// propagates, since this runs once per build Act and every other reply gets another chance next time.
    static func apply(context: ActContext, unansweredNightsMax: Int) async throws {
        for reply in try context.journal.unappliedCardReplies() {
            try await applyOne(reply, context: context, unansweredNightsMax: unansweredNightsMax)
        }
    }

    private static func applyOne(
        _ reply: CardReplyRecord, context: ActContext, unansweredNightsMax: Int
    ) async throws {
        let card = try context.journal.card(id: reply.cardID)
        switch reply.disposition {
        case .answer:
            try await applyAnswer(reply: reply, card: card, context: context)
        case .remark:
            try await applyRemark(reply: reply, card: card, context: context, unansweredNightsMax: unansweredNightsMax)
        case .divergence:
            try await applyDivergence(reply: reply, card: card, context: context)
        }
    }

    /// Claims the Card Lease for the one write, transitions the Card to Todo only while it is still
    /// Waiting on You / question (a later Act, or a hand-edit, may have moved it on already), releases
    /// the Lease, then acknowledges and marks applied. A Lease held by another run leaves the reply
    /// unapplied — retried by that run's own next build Act or this Project's next one.
    ///
    /// Once the Feature that put the Card in Waiting on You has landed (roadmap P11.3), lanes do not
    /// reopen: the answer is banked instead of dispatched, and this never touches the Card Lease, the
    /// Card's state, or the Worktree.
    private static func applyAnswer(reply: CardReplyRecord, card: CardRecord, context: ActContext) async throws {
        let journal = context.journal
        if try journal.isCycleLanded(cycleID: card.cycleID) {
            try await bankAnswer(reply: reply, card: card, context: context)
            return
        }
        switch try journal.claimCardLease(cardID: card.id, runID: context.runID) {
        case .held:
            return
        case .claimed, .reclaimed:
            break
        }
        do {
            let current = try journal.card(id: card.id)
            if current.state == .waitingOnYou, current.waitingReason == .question {
                try await transition(current, to: .ready, context: context)
            }
        } catch {
            _ = try? journal.releaseCardLease(cardID: card.id, runID: context.runID)
            throw error
        }
        _ = try journal.releaseCardLease(cardID: card.id, runID: context.runID)
        try await acknowledge(
            WaitingOnYouAcknowledgement.answer(), reply: reply, issueID: card.issueID, context: context
        )
        try journal.markCardReplyApplied(id: reply.id)
    }

    /// Banks an answer that arrived after the Feature landed (roadmap P11.3, OQ37): the Journal's own
    /// idempotent ``JournalStore/bankCardReply(id:stamps:nightID:act:runID:now:)`` reuses the stamps a
    /// retry after a crash first banked with, so the acknowledgement is always built from what the
    /// Journal returns, never from freshly computed stamps. Whether this reply is a repeat is decided
    /// from the Journal too: it is a repeat iff an earlier reply on the same Card is already banked.
    private static func bankAnswer(reply: CardReplyRecord, card: CardRecord, context: ActContext) async throws {
        let journal = context.journal
        let priorBanked = try journal.bankedCardReplies(cardID: card.id).contains { $0.reply.id < reply.id }
        let stamps = BankedReplyStamps.forCard(card, mainlines: context.mainlines)
        let banked = try journal.bankCardReply(
            id: reply.id, stamps: stamps, nightID: reply.nightID, act: context.act, runID: context.runID
        )
        let ackStamps = BankedReplyStamps.forAcknowledgement(card: card, stored: banked.stamps)
        try await acknowledge(
            WaitingOnYouAcknowledgement.banked(stamps: ackStamps, isRepeat: priorBanked),
            reply: reply, issueID: card.issueID, context: context
        )
        try journal.markCardReplyApplied(id: reply.id)
    }

    /// The Silence countdown reads the question this reply was classified against (nil when the Card
    /// had none recorded, or the reply predates P11.2): `nightsRemaining` is `unansweredNightsMax`
    /// unadjusted in that case, since no clock is running to subtract from.
    private static func applyRemark(
        reply: CardReplyRecord, card: CardRecord, context: ActContext, unansweredNightsMax: Int
    ) async throws {
        var questionText = ""
        var nightsRemaining = unansweredNightsMax
        if let questionID = reply.questionID, let question = try context.journal.cardQuestion(id: questionID) {
            questionText = question.question
            let elapsed = try context.journal.nightsElapsed(after: question.nightID, through: context.night.id)
            nightsRemaining = max(0, unansweredNightsMax - elapsed)
        }
        let body = WaitingOnYouAcknowledgement.remark(question: questionText, nightsRemaining: nightsRemaining)
        try await acknowledge(body, reply: reply, issueID: card.issueID, context: context)
        try context.journal.markCardReplyApplied(id: reply.id)
    }

    private static func applyDivergence(reply: CardReplyRecord, card: CardRecord, context: ActContext) async throws {
        try await acknowledge(
            WaitingOnYouAcknowledgement.divergence(), reply: reply, issueID: card.issueID, context: context
        )
        try context.journal.markCardReplyApplied(id: reply.id)
    }

    /// Through the board projection when a Board is bound, Journal-only otherwise — the same fallback
    /// every other seam in this phase uses, so a Journal-only Project still resumes the Card.
    private static func transition(_ card: CardRecord, to state: CardTransition, context: ActContext) async throws {
        if let board = context.board, let outbox = context.outbox {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            let projection = BoardStateProjection(journal: context.journal, outbox: outbox, scope: scope)
            _ = try await projection.transition(card: card, to: state)
        } else {
            _ = try context.journal.transitionCard(
                cardID: card.id, to: state.state, waitingReason: state.waitingReason, blockReason: state.blockReason,
                runID: context.runID, act: context.act, nightID: context.night.id
            )
        }
    }

    /// One acknowledgement comment, posted through the Outbox with no `cardID` — it is never gated by
    /// the Card Lease — under the idempotent key `waiting-on-you-reply:<commentID>:ack`. A no-op with no
    /// Board bound: nothing is posted, and the caller still marks the reply applied.
    private static func acknowledge(
        _ body: String, reply: CardReplyRecord, issueID: String, context: ActContext
    ) async throws {
        guard let outbox = context.outbox else { return }
        let key = "waiting-on-you-reply:\(reply.commentID):ack"
        let write = OutboxWrite(key: key, write: .createComment(issue: BoardObjectID(rawValue: issueID), body: body))
        _ = try await outbox.post(write)
    }
}
