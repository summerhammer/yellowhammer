import Domain
import Foundation
import Journal

/// What ``CardRun/conclude(_:frame:)`` decides once an Attempt has ended (roadmap P8.7): whether the run
/// is over, or a fresh Attempt on a different Route should be dispatched from the same held Lease, the
/// Card staying In Progress between them. `retry` carries the Attempt that just ended, so the reset
/// sequence (OQ60) knows whose work to preserve before the new one is recorded.
enum CardRunAction: Sendable {
    case stop
    case retry(AttemptRecord)
}

extension CardRun {
    /// Blocks a Card whose Attempt budget the routing guard (``CardRouting/route(card:repoRole:override:checkDeclaredNone:attemptsPerCard:)``)
    /// found already spent for `card`'s current budget epoch before any Attempt of this run: no Attempt
    /// was recorded and nothing was dispatched by this run, so the reset (OQ60) runs against the Card's
    /// last Attempt in history, if it has one, before the Block, and the Block Reason is the single
    /// derivation over the epoch's last ended Attempt (``AttemptHistory/blockReason(inEpoch:)``). The
    /// `attempts-exhausted` step's detail is the Operator-facing consumption account.
    func blockOnSpentAttemptBudget(card: CardRecord, frame: CardRunFrame) async throws {
        let history = try frame.journal.attemptHistory(cardID: card.id)
        let consumption = history.consumption(inEpoch: card.budgetEpoch)
        let reason = history.blockReason(inEpoch: card.budgetEpoch)
        try await attemptResetBeforeBlock(card: card, frame: frame)
        try frame.revalidateLease()
        try await frame.transition(.blocked(reason))
        try frame.record(.attemptsExhausted, detail: consumption.description)
    }

    /// The Operator-facing consumption account for `epoch`, read fresh from the Journal.
    func consumptionDescription(epoch: Int, frame: CardRunFrame) throws -> String {
        try frame.journal.attemptHistory(cardID: frame.card.id).consumption(inEpoch: epoch).description
    }
}
