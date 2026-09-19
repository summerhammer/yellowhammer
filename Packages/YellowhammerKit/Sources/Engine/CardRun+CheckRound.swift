import Domain
import Foundation
import Journal

/// The Round arithmetic of one open Attempt. Every failed judgement, whichever Lens made it, is a Round;
/// the worker is dispatched again only while the Rounds recorded are fewer than the most allowed. Both
/// Lenses share the one budget, and `recorded` is read back from the Journal, never counted in memory, so
/// a crash and a resume keep the count.
struct RoundBudget: Equatable, Sendable {
    let max: Int
    /// The Rounds recorded on the open Attempt so far, including the one just judged.
    let recorded: Int

    var allowsAnotherRound: Bool { recorded < max }
}

/// The Attempt arithmetic of one Card's current budget epoch: `attempts_per_card` is the Bound, and
/// `consumed` counts only Attempts whose ending actually consumed one — every ended Attempt but a
/// `question`, read back from the Journal's Attempt history, never counted in memory. A Card must never
/// block on the round budget alone: it blocks only once this budget is spent too.
struct AttemptBudget: Equatable, Sendable {
    let max: Int
    let consumed: Int

    var isExhausted: Bool { consumed >= max }
}

/// What the Card comment for a failed Check carries out of the Check's output: the full capped output lives
/// in the Journal, so the board copy is the last few KiB of it.
private let checkCommentOutputLimit = 8 * 1024

/// What one Round records, whichever Lens judged it: the Check's own loop and the review's
/// (`CardRun+ReviewRound.swift`) each build one and hand it to the shared recorder.
struct RoundToRecord: Sendable {
    let attemptID: Int64
    let lens: Lens
    let verdict: String
    let requestedChanges: String?
    let judgedCommit: String?
    /// The idempotency key prefix for the Card comment: distinct per Lens, so a Check Round and a review
    /// Round of the same ordinal never collide.
    let commentKeyPrefix: String
}

extension CardRun {
    /// The result of running the Check to green, or exhausting the round budget while it stayed red.
    enum CheckLoopOutcome: Sendable {
        case passed(commit: String, session: String?)
        case exhausted
    }

    /// Runs the Check, and while it fails records a Round and dispatches the worker again with every Round
    /// so far, until the Check passes (or is declared none) or the round budget is spent.
    func runCheckLoop(
        frame: CardRunFrame, attemptID: Int64, worked: (commit: String, session: String?)
    ) async throws -> CheckLoopOutcome {
        var worked = worked
        while true {
            let checked = try await runCheck(frame: frame, attemptID: attemptID)
            guard case .failed(let output, let exitStatus) = checked else {
                return .passed(commit: worked.commit, session: worked.session)
            }

            // A failed Check is a Round of this Attempt, never a new Attempt: same worker, Route, Worktree.
            let (rounds, budget) = try await recordCheckRound(
                frame: frame, attemptID: attemptID, commit: worked.commit, output: output, exitStatus: exitStatus
            )
            guard budget.allowsAnotherRound else {
                // A reviewer never sees red code.
                return .exhausted
            }
            worked = try await work(
                frame: frame, payloads: InstructionPayloads(roundFeedback: Self.feedback(of: rounds)),
                resumeSession: worked.session
            )
        }
    }

    /// Runs the Check over the worker's commit and records it: the `check` step (its outcome kind only, never
    /// the output) and the `checkRan` event (the output, capped by the runner).
    func runCheck(frame: CardRunFrame, attemptID: Int64) async throws -> RepositoryCheckResult {
        try frame.revalidateLease()
        let checked = try await check.run(
            repository: frame.card.repository, check: frame.check, worktreePath: frame.worktree.path
        )
        try frame.revalidateLease()
        try frame.record(.check, detail: Self.describe(checked))
        let card = frame.card
        let event: JournalEvent
        switch checked {
        case .passed(let printed):
            event = .checkRan(
                cardID: card.id, issueID: card.issueID, attemptID: attemptID, result: .passed, exitStatus: 0,
                output: printed
            )
        case .failed(let printed, let status):
            event = .checkRan(
                cardID: card.id, issueID: card.issueID, attemptID: attemptID, result: .failed, exitStatus: status,
                output: printed
            )
        case .declaredNone:
            event = .checkRan(
                cardID: card.id, issueID: card.issueID, attemptID: attemptID, result: .declaredNone,
                exitStatus: nil, output: nil
            )
        }
        try frame.journal.append(
            event, act: frame.context.act.act, runID: frame.context.act.runID, nightID: frame.context.act.night.id
        )
        return checked
    }

    /// Records a failed Check as a Round of the open Attempt (never an Attempt: nothing ends and no Route
    /// changes), attaches its output to the Card, and reads the Rounds back to say whether the worker may
    /// go again.
    func recordCheckRound(
        frame: CardRunFrame, attemptID: Int64, commit: String, output: String, exitStatus: Int32
    ) async throws -> (rounds: [RoundRecord], budget: RoundBudget) {
        let round = RoundToRecord(
            attemptID: attemptID, lens: .check, verdict: "failed", requestedChanges: output, judgedCommit: commit,
            commentKeyPrefix: "check-round"
        )
        return try await recordRound(round, frame: frame) { number in
            Self.checkRoundComment(
                round: number, command: frame.check.description, exitStatus: exitStatus, output: output
            )
        }
    }

    /// Records a Round of the open Attempt, whichever Lens judged it, and reads the Rounds back to say
    /// whether the worker may go again. Shared by the Check's and the review's Round loops (P8.5/P8.6):
    /// only the verdict, the comment and its idempotency key differ between them.
    func recordRound(
        _ round: RoundToRecord, frame: CardRunFrame, comment: (Int) -> String
    ) async throws -> (rounds: [RoundRecord], budget: RoundBudget) {
        try frame.revalidateLease()
        let recorded = try frame.journal.recordRound(
            attemptID: round.attemptID, lens: round.lens, verdict: round.verdict,
            requestedChanges: round.requestedChanges, judgedCommit: round.judgedCommit,
            runID: frame.context.act.runID
        )
        let rounds = try frame.journal.attemptHistory(cardID: frame.card.id).attempts
            .first { $0.id == round.attemptID }?.rounds ?? [recorded]

        // Without a Board there is nothing to post to; a later Act reposts, like every other board write.
        if let outbox = frame.context.act.outbox {
            try frame.revalidateLease()
            _ = try await outbox.post(OutboxWrite(
                key: "\(round.commentKeyPrefix):\(frame.card.issueID):\(recorded.id)",
                write: .createComment(issue: BoardObjectID(rawValue: frame.card.issueID), body: comment(rounds.count)),
                cardID: frame.card.id
            ))
        }
        return (rounds, RoundBudget(max: reviewRoundsMax, recorded: rounds.count))
    }

    /// The Card comment for a failed Check: which Round, the command, its status and the tail of its output.
    static func checkRoundComment(round: Int, command: String, exitStatus: Int32, output: String) -> String {
        var fence = "```"
        while output.contains(fence) { fence += "`" }
        let bytes = Array(output.utf8)
        // Lossy on purpose, as in ``WorktreeCheck``: the cut may fall inside a multi-byte scalar.
        // swiftlint:disable:next optional_data_string_conversion
        let tail = String(decoding: bytes.suffix(checkCommentOutputLimit), as: UTF8.self)
        let shown = bytes.count > checkCommentOutputLimit
            ? "[… \(bytes.count - checkCommentOutputLimit) earlier bytes of output omitted]\n" + tail
            : output
        return [
            "The engine-run Check failed for Round \(round): `\(command)` exited with status \(exitStatus).",
            "\(fence)\n\(shown)\n\(fence)",
            "A flaky Check blocks a Card that nothing was wrong with, and with a round budget this small it "
                + "does so quickly (risk R6)."
        ].joined(separator: "\n\n")
    }

    /// Every Round of the Attempt, numbered from 1, as the worker's next instruction carries them.
    static func feedback(of rounds: [RoundRecord]) -> [RoundFeedback] {
        rounds.enumerated().map { index, round in
            RoundFeedback(
                round: index + 1, lens: round.lens, verdict: round.verdict,
                requestedChanges: round.requestedChanges, judgedCommit: round.judgedCommit
            )
        }
    }
}
