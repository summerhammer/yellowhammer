import Domain
import Foundation
import Journal

// Auto-Blocking a Cycle's Waiting on You Cards, shared by every seam that costs a Card nothing to
// close over it: ``FeatureMergeClosure`` (roadmap P10.8) and the settle gesture's *released* value
// (roadmap P10.9). Both use the same Card Lease discipline.

enum CardAutoBlock {
    /// Every Waiting on You Card of `cycleID` is auto-Blocked `reply overdue` — the same exit
    /// `unanswered_nights_max` would have given it, with its counters and round history untouched.
    /// Cancelled, Done and already-Blocked Cards are never touched. Through the board projection when
    /// an Outbox and board are wired; Journal-only otherwise, so the auto-Block still happens.
    ///
    /// A Card's state write is delivered only under that Card's Lease, and the caller runs no Card:
    /// the Lease is claimed for the one write, then released, as the expired-lease sweep does — a
    /// lease left to expire would later read as a crashed run. A live lease held by another run throws,
    /// so the caller's closure is retried by its next pass rather than writing under it.
    static func waitingOnYou(cycleID: Int64, context: ActContext) async throws {
        let cards = try context.journal.cards(cycleID: cycleID).filter { $0.state == .waitingOnYou }
        try await block(cards: cards, reason: { _ in .replyOverdue }, context: context)
    }

    /// A released running Feature carries Todo and In Progress Cards forward as Blocked. Existing
    /// Blocked, Done and Cancelled Cards keep their state, reason and history.
    static func releasedActive(cycleID: Int64, context: ActContext) async throws {
        let cards = try context.journal.cards(cycleID: cycleID)
            .filter { $0.state == .todo || $0.state == .inProgress }
        try await block(cards: cards, reason: { _ in .featureAbandoned }, context: context)
    }

    /// Auto-Blocks specific Cards named by the caller (roadmap P11.4: the unanswered-Nights bound), each
    /// under the Block Reason `reason` computes for it — `reply overdue` on the `question` route,
    /// `decision overdue` on `divergence`. Never touches a Worktree: this bound's firing releases nothing but
    /// the Card's own board state, and a Worktree's exit is landing.
    static func specific(
        cards: [CardRecord], reason: @escaping (CardRecord) -> BlockReason, context: ActContext
    ) async throws {
        try await block(cards: cards, reason: reason, context: context)
    }

    /// The shared Card Lease dance every auto-Block seam uses: claim, write (through the board
    /// projection when one is wired, Journal-only otherwise), release. `reason` is evaluated per Card so
    /// a single call can carry a mix of Block Reasons.
    private static func block(
        cards: [CardRecord], reason: @escaping (CardRecord) -> BlockReason, context: ActContext
    ) async throws {
        guard !cards.isEmpty else { return }
        let journal = context.journal

        if let outbox = context.outbox, let board = context.board {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
            for card in cards {
                if case .held(let holder) = try journal.claimCardLease(cardID: card.id, runID: context.runID) {
                    throw CycleArchiveFault(
                        reason: "Card '\(card.issueID)' is held by run \(holder.runID); its auto-Block is retried"
                    )
                }
                do {
                    _ = try await projection.transition(card: card, to: .blocked(reason(card)))
                } catch {
                    _ = try? journal.releaseCardLease(cardID: card.id, runID: context.runID)
                    throw error
                }
                try journal.releaseCardLease(cardID: card.id, runID: context.runID)
            }
        } else {
            for card in cards {
                _ = try journal.transitionCard(
                    cardID: card.id, to: .blocked, blockReason: reason(card), runID: context.runID,
                    act: context.act, nightID: context.night.id
                )
            }
        }
    }
}
