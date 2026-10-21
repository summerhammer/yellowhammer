import Domain
import Foundation
import Journal

extension CardRun {
    /// Reports a refused Card override onto the Card (G-17, OQ126): one comment through the Outbox, keyed by
    /// the refusal so a later Act refusing it the same way does not post it again. Without an Outbox the
    /// Journal's `OverrideRefused` event, which the Night Summary reads, is the whole report.
    func reportOverrideRefusal(_ refusal: OverrideRefusal, frame: CardRunFrame) async throws {
        guard let outbox = frame.context.act.outbox else { return }
        try frame.revalidateLease()
        let card = frame.card
        let body = [
            "This Card was not dispatched and consumed no Attempt: its Card override was refused.",
            "- \(refusal.description)",
            "Correct the `Card override:` line in the description, or empty it, to run the Card."
        ].joined(separator: "\n")
        let key = "override-refused:\(card.issueID):\(ManagedBlockFence.sha256(refusal.description))"
        _ = try await outbox.post(OutboxWrite(
            key: key, write: .createComment(issue: BoardObjectID(rawValue: card.issueID), body: body), cardID: card.id
        ))
    }
}
