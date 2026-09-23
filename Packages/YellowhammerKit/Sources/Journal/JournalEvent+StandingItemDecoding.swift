import Domain
import Foundation

// The payload and decode of the two promotion Bounds' own events, `refusalPromotedToStandingItem` and
// `cardPromotedToStandingItem` (roadmap P11.6; bounds/overview,
// bounds/overview), split out of JournalEvent+Payload.swift and JournalEvent+Decoding.swift
// to keep those files under the file length limit.

extension JournalEvent {
    var refusalPromotedToStandingItemPayload: [String: String]? {
        guard case .refusalPromotedToStandingItem(
            let feature, let consecutiveRefusals, let consecutiveRefusalsMax
        ) = self else {
            return nil
        }
        return [
            "feature": feature, "consecutive_refusals": String(consecutiveRefusals),
            "consecutive_refusals_max": String(consecutiveRefusalsMax)
        ]
    }

    var cardPromotedToStandingItemPayload: [String: String]? {
        guard case .cardPromotedToStandingItem(
            let cardID, let issueID, let failedAdoptions, let failedAdoptionsMax
        ) = self else {
            return nil
        }
        return [
            "card_id": String(cardID), "issue_id": issueID, "failed_adoptions": String(failedAdoptions),
            "failed_adoptions_max": String(failedAdoptionsMax)
        ]
    }

    static func decodeRefusalPromotedToStandingItem(_ reader: PayloadReader) throws -> JournalEvent {
        .refusalPromotedToStandingItem(
            feature: try reader.require("feature"),
            consecutiveRefusals: try reader.int("consecutive_refusals"),
            consecutiveRefusalsMax: try reader.int("consecutive_refusals_max")
        )
    }

    static func decodeCardPromotedToStandingItem(_ reader: PayloadReader) throws -> JournalEvent {
        .cardPromotedToStandingItem(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            failedAdoptions: try reader.int("failed_adoptions"),
            failedAdoptionsMax: try reader.int("failed_adoptions_max")
        )
    }
}
