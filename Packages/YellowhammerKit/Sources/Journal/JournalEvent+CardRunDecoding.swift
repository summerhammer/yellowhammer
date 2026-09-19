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

    static func decodeFailureCauseRecorded(_ reader: PayloadReader) throws -> JournalEvent {
        .failureCauseRecorded(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            cause: try reader.require("cause"),
            causeHash: try reader.require("cause_hash"),
            recurrenceCount: try reader.int("recurrence_count")
        )
    }

    static func decodeCheckRan(_ reader: PayloadReader) throws -> JournalEvent {
        guard let result = CheckRunResult(rawValue: try reader.require("result")) else {
            throw JournalError.eventUnreadable(id: reader.rowID)
        }
        return .checkRan(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            result: result,
            exitStatus: reader.payload?["exit_status"].flatMap { Int32($0) },
            output: reader.payload?["output"]
        )
    }
}
