import Domain
import Foundation
import Journal

// The Waiting on You reply classification and recording (roadmap P11.2; spec: bounds/escalate-a-
// question-to-the-operator, board-projection/read-board-changes-by-delta, G-8), split out of
// DeltaRead.swift to keep that file under the type-length limit. Dispatched from `reconcile`, after the
// objects loop (so a Card Cancelled in this same read is never treated as waiting) and before the sync
// point moves, so a crash before this runs loses nothing: the same comments are read again on the next
// Act and recording is idempotent on the board comment id.

extension DeltaRead {
    /// Classifies and records every human comment against a Card that is, as the Journal now reads it,
    /// in Waiting on You. Never inspects a comment's content, only its `parent`.
    func classifyAndRecordReplies(into report: inout DeltaReadReport) throws {
        guard let nightID else { return }
        for human in report.humanComments {
            guard let card = try journal.card(issueID: human.comment.issue.rawValue) else { continue }
            guard card.state == .waitingOnYou, let waitingReason = card.waitingReason else { continue }

            switch waitingReason {
            case .divergence, .overreach:
                let draft = CardReplyDraft(
                    cardID: card.id, issueID: card.issueID, questionID: nil, commentID: human.comment.id.rawValue,
                    body: human.comment.body, authorName: human.comment.author.name,
                    disposition: waitingReason == .overreach ? .overreach : .divergence,
                    commentedAt: human.comment.createdAt
                )
                try recordReply(draft, nightID: nightID, into: &report)
            case .question:
                let question = try journal.latestCardQuestion(cardID: card.id)
                let disposition = try answerDisposition(comment: human.comment, question: question)
                let draft = CardReplyDraft(
                    cardID: card.id, issueID: card.issueID, questionID: question?.id,
                    commentID: human.comment.id.rawValue, body: human.comment.body,
                    authorName: human.comment.author.name, disposition: disposition,
                    commentedAt: human.comment.createdAt
                )
                try recordReply(draft, nightID: nightID, into: &report)
            }
        }
    }

    /// `answer` only when the comment is a threaded reply whose parent names the latest recorded
    /// question's own comment — matched against the Outbox entry's `result` (the id the board actually
    /// gave the question comment) and against `comment_client_id` itself, case-insensitively either way,
    /// since a board may report ids in a different case than they were minted. Every other comment,
    /// including one with no recorded question behind it at all, is a `remark`.
    private func answerDisposition(
        comment: BoardComment, question: CardQuestionRecord?
    ) throws -> CardReplyDisposition {
        guard let question, let clientID = question.commentClientID, let parent = comment.parent else {
            return .remark
        }
        let parentID = parent.rawValue
        if parentID.caseInsensitiveCompare(clientID) == .orderedSame {
            return .answer
        }
        if let uuid = UUID(uuidString: clientID), let entry = try journal.outboxEntry(clientID: uuid),
           let result = entry.result, parentID.caseInsensitiveCompare(result) == .orderedSame {
            return .answer
        }
        return .remark
    }

    private func recordReply(_ draft: CardReplyDraft, nightID: Int64, into report: inout DeltaReadReport) throws {
        let recorded = try journal.recordCardReply(draft, nightID: nightID, act: act, runID: runID, now: clock())
        report.waitingOnYouReplies.append(recorded)
    }
}
