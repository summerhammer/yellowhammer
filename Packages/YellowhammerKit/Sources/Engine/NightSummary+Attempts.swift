import Domain
import Foundation
import Journal

// How the Night Summary names a Card and words one of its Attempts (roadmap P12.1).

extension NightSummary {
    /// A Card's name in the Night Summary: its identifier (`YLH-312`) — never the issue's UUID unless the
    /// Journal holds nothing else — linked to the issue when its URL is recorded, else in backticks.
    static func cardName(_ card: CardRecord) -> String {
        let key = card.issueIDForDisplay ?? card.issueKey ?? card.issueID
        guard let url = card.issueURL else { return "`\(key)`" }
        return "[\(key)](\(url))"
    }

    /// One Attempt of a Card: `Attempt 2: agy/gemini-3.8-flash, success; check: passed on `b763aff` after
    /// 1 failed run; rounds: check(failed)`. The result and its classification are the Attempt's own record
    /// ("not ended" while open; a success's classification is left out, it says nothing the result does
    /// not), `work preserved` is said when its work was kept under a git ref, and the
    /// Check result comes from `checkRuns` (the Card's, filtered here to this Attempt), not from Rounds.
    static func attemptSummary(ordinal: Int, _ attempt: AttemptRecord, checkRuns: [CheckRunRecord]) -> String {
        var ending = attempt.result ?? "not ended"
        if let classification = attempt.classification, attempt.result != AttemptOutcome.success.rawValue {
            ending += " (\(classification))"
        }
        if attempt.preservedRef != nil {
            ending += ", work preserved"
        }
        let check = AttemptAccount.checkResult(
            checkDeclaredNone: attempt.checkDeclaredNone, runs: checkRuns.filter { $0.attemptID == attempt.id }
        )
        let rounds = attempt.rounds.isEmpty
            ? "none"
            : attempt.rounds.map { "\($0.lens.rawValue)(\($0.verdict))" }.joined(separator: ", ")
        return "Attempt \(ordinal): \(attempt.route.cli)/\(attempt.route.model), \(ending); check: \(check); "
            + "rounds: \(rounds)"
    }
}
