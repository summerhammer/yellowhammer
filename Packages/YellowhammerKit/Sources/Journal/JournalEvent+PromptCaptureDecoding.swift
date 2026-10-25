import Domain
import Foundation

// The prompt capture event's decode helper (app/view-the-prompts-used-by-a-pass),
// split out of JournalEvent+Decoding.swift (whose exhaustive switch still dispatches to it) to keep
// that file under the file length limit.

extension JournalEvent {
    static func decodePromptCaptureRequested(_ reader: PayloadReader) throws -> JournalEvent {
        .promptCaptureRequested(
            recordID: try reader.require("record_id"),
            pass: try reader.pass("pass"),
            cardID: reader.payload?["card_id"].flatMap { Int64($0) },
            issueID: reader.payload?["issue_id"],
            attemptID: reader.payload?["attempt_id"].flatMap { Int64($0) },
            round: reader.payload?["round"].flatMap { Int($0) },
            ordinal: reader.payload?["ordinal"].flatMap { Int($0) }
        )
    }
}
