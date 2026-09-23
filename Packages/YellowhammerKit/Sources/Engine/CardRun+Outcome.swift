import Domain
import Foundation
import Journal

extension CardRun {
    /// Tells the Journal how the run ended, revalidating the Lease before each write, and decides whether
    /// this Card run is over or a fresh Attempt should be dispatched (roadmap P8.7). Only a reviewer
    /// approval after a passing (or declared-none) Check ends the Attempt in success and moves the Card to
    /// Done; a question ends the run without consuming the Attempt budget or retrying, moving the Card to
    /// Waiting on You instead (roadmap P11.1); every other ending — hard failure, Crashed-Unknown,
    /// `rounds-exhausted` — retries while the Attempt budget has room, and Blocks the Card once it is spent.
    func conclude(_ end: CardRunEnd, frame: CardRunFrame) async throws -> CardRunAction {
        switch end {
        case .approved(let commit):
            try endAttempt(.success, frame: frame)
            // The Card's work is judged good, so a reset must never rewind it (object-guide: Worktree).
            try frame.revalidateLease()
            try frame.journal.recordWorktreeKnownGood(
                id: frame.worktree.id, commit: commit, runID: frame.context.act.runID
            )
            try await frame.transition(.done)
            return .stop

        case .asked(let question):
            return try await concludeAsked(question, frame: frame)

        case .ending(let ending):
            try endAttempt(ending, frame: frame)
            guard ending.consumesAttempt else {
                try await frame.transition(.ready)
                return .stop
            }
            // A hard failure or Crashed-Unknown: a fresh Attempt on a different Route while the Attempt
            // budget has room (P8.7); the Card stays In Progress between Attempts.
            guard let attempt = frame.attempt else { return .stop }
            return try await retryOrBlock(attempt: attempt, cause: FailureCause(ending: ending), frame: frame)

        case .roundsExhausted(let lens):
            // The Round that spent the round budget was already recorded, on either Lens's own loop. This
            // ends the Attempt `rounds-exhausted` — that Round's own comment already told the board why —
            // and then decides the Card's fate from the Attempt budget, not the round budget alone.
            guard let attempt = frame.attempt else { return .stop }
            let roundCount = try frame.journal.attemptHistory(cardID: frame.card.id).attempts
                .first { $0.id == attempt.id }?.rounds.count ?? 0
            let ending = AttemptEnding.roundsExhausted(rounds: roundCount)
            try endAttempt(ending, frame: frame)
            try frame.revalidateLease()
            try frame.record(.roundsExhausted, detail: lens.rawValue)
            let cause = FailureCause(ending: ending, lens: lens)
            return try await retryOrBlock(attempt: attempt, cause: cause, frame: frame)
        }
    }

    /// A worker's question ends the Attempt `question` — consuming no Round and no Attempt, and never
    /// retrying, since there is no Attempt budget spent to retry with — records the question in the
    /// Journal, moves the Card to Waiting on You (assigned to the Operator identity when it is
    /// configured and still an active workspace member), and posts the question as a comment through the
    /// Outbox. The Worktree is left exactly as the Attempt left it (roadmap P11.1; spec: bounds/
    /// escalate-a-question-to-the-operator).
    private func concludeAsked(_ question: String, frame: CardRunFrame) async throws -> CardRunAction {
        try endAttempt(.question, frame: frame)
        try frame.revalidateLease()
        guard let attempt = frame.attempt else { return .stop }

        let outbox = frame.context.act.outbox
        let key = "question:\(frame.card.issueID):\(attempt.id)"
        let commentClientID = outbox.map { $0.clientID(for: key).uuidString }

        try frame.journal.recordCardQuestion(
            cardID: frame.card.id, attemptID: attempt.id, question: question, commentClientID: commentClientID,
            nightID: frame.context.act.night.id, act: frame.context.act.act, runID: frame.context.act.runID
        )

        let assignee = await frame.context.act.operatorIdentity.assignee(on: frame.context.act.board?.reading)
        try await frame.transition(.waitingOnYou(.question, operator: assignee))

        if let outbox {
            try frame.revalidateLease()
            let body = Self.questionCommentBody(question)
            let write = OutboxWrite(
                key: key, write: .createComment(issue: BoardObjectID(rawValue: frame.card.issueID), body: body),
                cardID: frame.card.id
            )
            _ = try await outbox.post(write)
        }
        return .stop
    }

    /// First line states the consequence, then the question as a Markdown blockquote — nothing here
    /// judges the question's content, only carries it (P11.1).
    private static func questionCommentBody(_ question: String) -> String {
        """
        Waiting on You: the worker stopped to ask rather than guess. Reply in this thread to answer; \
        this consumed no Round and no Attempt.

        > \(question)
        """
    }

    /// Shared by every consuming ending: retries with a fresh Attempt while the Attempt budget has room,
    /// Blocks the Card once it is spent — never on the round budget alone. The Block Reason is the
    /// single derivation over the epoch's last ended Attempt (``AttemptHistory/blockReason(inEpoch:)``),
    /// not something this caller decides from which ending it just recorded.
    ///
    /// Before either, the failure's cause is counted (roadmap P8.8): a cause this Project's Journal
    /// already met on an earlier Night promotes the Card to Triage rather than retrying it on a further
    /// Route, even with Attempt budget left.
    private func retryOrBlock(
        attempt: AttemptRecord, cause: FailureCause?, frame: CardRunFrame
    ) async throws -> CardRunAction {
        if let cause, let promotion = try recurrence(of: cause, frame: frame) {
            try await block(after: attempt, frame: frame)
            try frame.record(.promotedToTriage, detail: promotion)
            return .stop
        }
        let budget = try attemptBudget(consumedInEpochOf: attempt, frame: frame)
        guard budget.isExhausted else {
            // The round budget alone never blocks a Card, and neither does a lone hard failure or
            // Crashed-Unknown while Attempts remain: this run dispatches a fresh Attempt on a different
            // Route rather than returning the Card to Ready.
            return .retry(attempt)
        }
        try await block(after: attempt, frame: frame)
        let account = try consumptionDescription(epoch: attempt.budgetEpoch, frame: frame)
        try frame.record(.attemptsExhausted, detail: account)
        return .stop
    }

    /// Blocks the Card on the final Attempt's termination — the one Block sequence, whether the Attempt
    /// budget was spent or the failure cause recurred.
    private func block(after attempt: AttemptRecord, frame: CardRunFrame) async throws {
        let reason = try frame.journal.attemptHistory(cardID: frame.card.id).blockReason(inEpoch: attempt.budgetEpoch)
        // The reset runs after the Attempt is ended and before the Blocked transition (OQ60); the Card
        // still Blocks whether it succeeds or fails.
        _ = try await attemptReset(priorAttemptID: attempt.id, frame: frame)
        try frame.revalidateLease()
        try await frame.transition(.blocked(reason))
    }

    /// Counts `cause` against the Card for this Act's Night and returns the Operator-facing promotion
    /// reason when it has recurred across separate Nights, nil on a first occurrence. The spec names no
    /// board state for the Triage disposition (loop-state/record-failure-cause-recurrence): a promoted
    /// Card is Blocked, on the final Attempt's Block Reason, and carries the promotion beside it.
    private func recurrence(of cause: FailureCause, frame: CardRunFrame) throws -> String? {
        try frame.revalidateLease()
        let record = try frame.journal.recordFailureCause(
            cardID: frame.card.id, cause: cause, nightID: frame.context.act.night.id,
            runID: frame.context.act.runID, act: frame.context.act.act
        )
        guard record.hasRecurred else { return nil }
        return TriagePromotion(cause: cause.summary, nights: record.recurrenceCount).reason
    }

    /// The Attempt budget for the epoch `endedAttempt` just ended: `consumed` counts every ended Attempt
    /// of that epoch whose ending consumed one, `endedAttempt` itself included — a `question` never
    /// counts, and it is the only ending that does not. Reads the single source of consumption counting,
    /// ``AttemptHistory/consumption(inEpoch:)``.
    private func attemptBudget(
        consumedInEpochOf endedAttempt: AttemptRecord, frame: CardRunFrame
    ) throws -> AttemptBudget {
        let history = try frame.journal.attemptHistory(cardID: frame.card.id)
        let consumed = history.consumption(inEpoch: endedAttempt.budgetEpoch).consumed
        return AttemptBudget(max: attemptsPerCard, consumed: consumed)
    }

    private func endAttempt(_ ending: AttemptEnding, frame: CardRunFrame) throws {
        guard let attempt = frame.attempt else { return }
        try frame.revalidateLease()
        try frame.journal.endAttempt(
            attemptID: attempt.id, ending: ending, runID: frame.context.act.runID, act: frame.context.act.act,
            nightID: frame.context.act.night.id
        )
    }
}
