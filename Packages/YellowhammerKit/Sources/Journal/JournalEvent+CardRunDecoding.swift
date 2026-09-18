import Domain
import Foundation

// The Card run's event decode helper (graph-execution/run-a-card, P8.4), split out of
// JournalEvent+Decoding.swift (whose exhaustive switch still dispatches to it) to keep that file under
// the file length limit.

extension JournalEvent {
    static func decodeCardRunStep(_ reader: PayloadReader) throws -> JournalEvent {
        guard let step = CardRunStep(rawValue: try reader.require("step")) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .cardRunStep(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            step: step,
            detail: reader.payload?["detail"]
        )
    }
}
