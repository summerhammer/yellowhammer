import Domain
import Foundation
import Journal

/// What ``CardRun/conclude(_:frame:)`` decides once an Attempt has ended (roadmap P8.7): whether the run
/// is over, or a fresh Attempt on a different Route should be dispatched from the same held Lease, the
/// Card staying In Progress between them.
enum CardRunAction: Sendable {
    case stop
    case retry
}

extension CardRun {
    /// Blocks a Card whose Attempt budget the routing guard (``CardRouting/route(card:repoRole:override:checkDeclaredNone:attemptsPerCard:)``)
    /// found already spent for `card`'s current budget epoch before any Attempt of this run: no Attempt
    /// was recorded and nothing was dispatched, so the Block Reason is derived from the epoch's last
    /// consuming Attempt already in the Journal, and the `attempts-exhausted` step's detail is the
    /// Operator-facing consumption account.
    func blockOnSpentAttemptBudget(card: CardRecord, frame: CardRunFrame) async throws {
        let history = try frame.journal.attemptHistory(cardID: card.id)
        let consumption = history.consumption(inEpoch: card.budgetEpoch)
        let lastConsuming = history.attempts.last {
            $0.budgetEpoch == card.budgetEpoch && $0.result != nil
                && $0.result != AttemptOutcome.question.rawValue
        }
        let reason = Self.blockReason(
            lastEndingOutcome: lastConsuming?.result, lastRoundLens: lastConsuming?.rounds.last?.lens
        )
        try frame.revalidateLease()
        try await frame.transition(.blocked(reason))
        try frame.record(.attemptsExhausted, detail: consumption.description)
    }

    /// The Block Reason for a Card whose Attempt budget is spent: `rounds-exhausted` blocks by the last
    /// Round's Lens (P8.6's rule, unchanged); a hard failure or Crashed-Unknown — or no ending at all,
    /// which cannot happen once the budget is spent but is handled the same way — blocks `hard failure`.
    static func blockReason(lastEndingOutcome: String?, lastRoundLens: Lens?) -> BlockReason {
        guard lastEndingOutcome == AttemptOutcome.roundsExhausted.rawValue, let lens = lastRoundLens else {
            return .hardFailure
        }
        return lens == .check ? .blockedByCheck : .blockedByReviewer
    }

    /// The Operator-facing consumption account for `epoch`, read fresh from the Journal.
    func consumptionDescription(epoch: Int, frame: CardRunFrame) throws -> String {
        try frame.journal.attemptHistory(cardID: frame.card.id).consumption(inEpoch: epoch).description
    }
}
