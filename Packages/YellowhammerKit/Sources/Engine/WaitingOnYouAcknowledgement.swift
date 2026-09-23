import Foundation

/// The Operator-facing acknowledgement comments for a human reply on a Card in Waiting on You (roadmap
/// P11.2; spec: bounds/escalate-a-question-to-the-operator, OQ37). One per human comment, posted through
/// the Outbox under the idempotent key `waiting-on-you-reply:<commentID>:ack`, with no `cardID` on the
/// write — the acknowledgement is never gated by the Card Lease. The canonical copy is reproduced
/// exactly, markdown included; the first line always states the consequence.
///
/// A fourth body — banked, posted only once the Feature lands — is P11.3's and is not here.
enum WaitingOnYouAcknowledgement {
    /// (a) An answer: the Card left Waiting on You and is queued to resume.
    static func answer() -> String {
        """
        **It runs on the next build Act.**

        Yellowhammer recognised your reply as an answer to the question. This Card has been moved out of \
        `Waiting on You` and queued to resume dispatch on the next build Act. Your answer and question \
        history will be supplied to the agent.
        """
    }

    /// (b) A remark on a Card still Waiting on You for a question: recorded, but the Card is untouched.
    /// `question` is the recorded question's text, already summarized (``summarize(question:)``).
    /// `nightsRemaining` is `max(0, unansweredNightsMax - elapsed)`, the Silence countdown.
    static func remark(question: String, nightsRemaining: Int) -> String {
        """
        **Nothing changed; \(nightsRemaining) nights remain on the clock.**

        Yellowhammer recorded your comment, but did not recognise it as an answer to the outstanding \
        question. The Card remains in `Waiting on You`. **To answer, reply directly in the question \
        comment's thread** — a comment elsewhere on the Card is never read as an answer.

        - **Question awaiting answer:** "\(summarize(question: question))"
        - **Silence countdown:** \(nightsRemaining) nights remaining before this Card is automatically \
        converted to `Blocked` (`block_reason = unanswered`).
        """
    }

    /// (d) A reply to a Divergence notice: recorded and acknowledged only, never carried forward.
    static func divergence() -> String {
        """
        **Nothing runs, and nothing is carried forward.**

        This Card is in `Waiting on You` due to a Divergence notice (repository movement invalidated \
        earlier assumptions). A Divergence notice is a report of repository state, not an agent \
        question, and cannot be resolved by replying to this thread.

        Your comment has been recorded in the Journal, but no build Act will resume and this comment \
        will not be carried into future Adoption dispatches. To proceed, either cancel this Card or \
        author replacement work in a new Feature.
        """
    }

    /// The recorded question's text with newlines collapsed to spaces, truncated to 200 characters with
    /// "…" appended when longer.
    static func summarize(question: String) -> String {
        let collapsed = String(question.map { $0.isNewline ? " " : $0 })
        guard collapsed.count > 200 else { return collapsed }
        return String(collapsed.prefix(200)) + "…"
    }
}
