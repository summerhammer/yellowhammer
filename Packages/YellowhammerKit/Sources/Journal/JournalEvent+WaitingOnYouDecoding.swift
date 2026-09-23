import Domain
import Foundation

// The decode and payload helpers of the two events that put a Card in Waiting on You under
// `waiting_reason = question` — the protected-path refusal (P8.3) and the worker's question (P11.1) —
// split out of JournalEvent+Decoding.swift and JournalEvent+Payload.swift to keep those files under the
// file length limit, as the settle gesture's are in JournalEvent+SettleDecoding.swift.

extension JournalEvent {
    static func decodeWaitingOnYou(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        switch type {
        case .protectedPathRefused:
            try decodeProtectedPathRefused(reader)
        default:
            try decodeCardQuestionAsked(reader)
        }
    }

    /// The payload of both events, dispatched here so the exhaustive payload switch stays one line for
    /// the two.
    var waitingOnYouPayload: [String: String]? {
        switch self {
        case .protectedPathRefused(let cardID, let issueID, let repository, let declaredPath, let protectedPath):
            [
                "card_id": String(cardID), "issue_id": issueID, "repository": repository,
                "declared_path": declaredPath, "protected_path": protectedPath
            ]
        case .cardQuestionAsked(let cardID, let issueID, let attemptID):
            ["card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID)]
        default:
            nil
        }
    }

    static func decodeProtectedPathRefused(_ reader: PayloadReader) throws -> JournalEvent {
        .protectedPathRefused(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            repository: try reader.require("repository"), declaredPath: try reader.require("declared_path"),
            protectedPath: try reader.require("protected_path")
        )
    }

    static func decodeCardQuestionAsked(_ reader: PayloadReader) throws -> JournalEvent {
        .cardQuestionAsked(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id")
        )
    }
}
