import Domain
import Foundation

// The flush firing's own event (Transient Board Failure Ruling 2026-10-09 item 6), split out of
// JournalEvent+Decoding.swift and JournalEvent+Payload.swift to keep those files under the file length
// limit — the same reason Project removal's live in JournalEvent+ProjectRemovalDecoding.swift.

extension JournalEvent {
    var flushFiringRanPayload: [String: String]? {
        guard case .flushFiringRan(let outcome, let detail) = self else { return nil }
        var dict = ["outcome": outcome.rawValue]
        if let detail {
            dict["detail"] = detail
        }
        return dict
    }

    static func decodeFlushFiringRan(_ reader: PayloadReader) throws -> JournalEvent {
        guard let outcome = FlushFiringOutcome(rawValue: try reader.require("outcome")) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .flushFiringRan(outcome: outcome, detail: reader.payload?["detail"])
    }
}
