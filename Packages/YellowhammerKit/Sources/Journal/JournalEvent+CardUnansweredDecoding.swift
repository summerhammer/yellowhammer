import Domain
import Foundation

// The payload and decode of `cardUnansweredBoundFired` (roadmap P11.4; spec:
// bounds/bound-unanswered-nights), split out of JournalEvent+Payload.swift and
// JournalEvent+Decoding.swift to keep those files under the file length limit, as the Refusal and
// Authoring Halt clocks' events are split into their own files too.

extension JournalEvent {
    var cardUnansweredBoundFiredPayload: [String: String]? {
        guard case .cardUnansweredBoundFired(
            let cardID, let issueID, let unansweredNights, let bound, let blockReason
        ) = self else {
            return nil
        }
        return [
            "card_id": String(cardID), "issue_id": issueID, "unanswered_nights": String(unansweredNights),
            "bound": String(bound), "block_reason": blockReason
        ]
    }

    static func decodeCardUnansweredBoundFired(_ reader: PayloadReader) throws -> JournalEvent {
        .cardUnansweredBoundFired(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            unansweredNights: try reader.int("unanswered_nights"),
            bound: try reader.int("bound"),
            blockReason: try reader.require("block_reason")
        )
    }
}
