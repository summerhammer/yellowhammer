import Domain
import Foundation
import Journal

extension PulseSnapshot {
    /// The endings of a Card's latest Attempt that leave it waiting for nothing but the Operator or a usage limit.
    private static let stallingEndings: Set<String> = [
        AttemptOutcome.roundsExhausted.rawValue, AttemptOutcome.hardFailure.rawValue,
        AttemptOutcome.usageLimited.rawValue
    ]

    /// Why an in-flight Feature with no running Attempt is not moving: every remaining Card (not done, shelved,
    /// Blocked or Waiting on You) is Todo and its latest Attempt failed or hit a usage limit. Nil otherwise,
    /// including when any Card has no Attempt yet.
    static func stallNote(
        _ journal: JournalStore, cards: [CardRecord], runningAttempts: [RunningAttempt]
    ) throws -> String? {
        guard runningAttempts.isEmpty else { return nil }
        let excluded: Set<CardState> = [.done, .shelved, .blocked, .waitingOnYou]
        let remaining = cards.filter { !excluded.contains($0.state) }
        guard !remaining.isEmpty, remaining.allSatisfy({ $0.state == .todo }) else { return nil }
        for card in remaining {
            guard let latest = try journal.attemptHistory(cardID: card.id).attempts.last,
                  let result = latest.result, stallingEndings.contains(result) else { return nil }
        }
        let names = remaining.map { $0.issueIDForDisplay ?? $0.issueKey ?? $0.issueID }
        return "Stalled — the last Attempt on every remaining Card failed or hit a usage limit "
            + "(\(names.joined(separator: ", ")))"
    }
}
