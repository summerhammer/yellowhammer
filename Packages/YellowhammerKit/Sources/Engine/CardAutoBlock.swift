import Domain
import Foundation
import Journal

// Auto-Blocking a Cycle's Waiting on You Cards, shared by every seam that costs a Card nothing to
// close over it: ``FeatureMergeClosure`` (roadmap P10.8) and the settle gesture's *released* value
// (roadmap P10.9). Extracted here rather than duplicated, since both write the identical Block Reason
// under the identical Card Lease discipline.

enum CardAutoBlock {
    /// Every Waiting on You Card of `cycleID` is auto-Blocked `unanswered` — the same exit
    /// `unanswered_nights_max` would have given it, with its counters and round history untouched.
    /// Cancelled, Done and already-Blocked Cards are never touched. Through the board projection when
    /// an Outbox and board are wired; Journal-only otherwise, so the auto-Block still happens.
    ///
    /// A Card's state write is delivered only under that Card's Lease, and the caller runs no Card:
    /// the Lease is claimed for the one write, then released, as the expired-lease sweep does — a
    /// lease left to expire would later read as a crashed run. A live lease held by another run throws,
    /// so the caller's closure is retried by its next pass rather than writing under it.
    static func waitingOnYou(cycleID: Int64, context: ActContext) async throws {
        let journal = context.journal
        let waiting = try journal.cards(cycleID: cycleID).filter { $0.state == .waitingOnYou }
        guard !waiting.isEmpty else { return }

        if let outbox = context.outbox, let board = context.board {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
            for card in waiting {
                if case .held(let holder) = try journal.claimCardLease(cardID: card.id, runID: context.runID) {
                    throw CycleArchiveFault(
                        reason: "Card '\(card.issueID)' is held by run \(holder.runID); its auto-Block is retried"
                    )
                }
                do {
                    _ = try await projection.transition(card: card, to: .blocked(.unanswered))
                } catch {
                    _ = try? journal.releaseCardLease(cardID: card.id, runID: context.runID)
                    throw error
                }
                try journal.releaseCardLease(cardID: card.id, runID: context.runID)
            }
        } else {
            for card in waiting {
                _ = try journal.transitionCard(
                    cardID: card.id, to: .blocked, blockReason: .unanswered, runID: context.runID,
                    act: context.act, nightID: context.night.id
                )
            }
        }
    }
}
