import Domain
import Foundation
import Journal

/// The Round arithmetic of one open Attempt. Every failed judgement, whichever Lens made it, is a Round;
/// the worker is dispatched again only while the Rounds recorded are fewer than the most allowed. Both
/// Lenses share the one budget, and `recorded` is read back from the Journal, never counted in memory, so
/// a crash and a resume keep the count. (`review_rounds_max` is the Bound; roadmap P8.6 reuses this.)
struct RoundBudget: Equatable, Sendable {
    let max: Int
    /// The Rounds recorded on the open Attempt so far, including the one just judged.
    let recorded: Int

    var allowsAnotherRound: Bool { recorded < max }
}

/// What the Card comment for a failed Check carries out of the Check's output: the full capped output lives
/// in the Journal, so the board copy is the last few KiB of it.
private let checkCommentOutputLimit = 8 * 1024

extension CardRun {
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
        try frame.revalidateLease()
        let round = try frame.journal.recordRound(
            attemptID: attemptID, lens: .check, verdict: "failed", requestedChanges: output, judgedCommit: commit,
            runID: frame.context.act.runID
        )
        let rounds = try frame.journal.attemptHistory(cardID: frame.card.id).attempts
            .first { $0.id == attemptID }?.rounds ?? [round]

        // Without a Board there is nothing to post to; a later Act reposts, like every other board write.
        if let outbox = frame.context.act.outbox {
            try frame.revalidateLease()
            let body = Self.checkRoundComment(
                round: rounds.count, command: frame.check.description, exitStatus: exitStatus, output: output
            )
            _ = try await outbox.post(OutboxWrite(
                key: "check-round:\(frame.card.issueID):\(round.id)",
                write: .createComment(issue: BoardObjectID(rawValue: frame.card.issueID), body: body),
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
