import Foundation

// The commit-trailer events' decode helpers (graph-execution/run-a-card), split out of
// JournalEvent+Decoding.swift (whose exhaustive switch dispatches to them) to keep that file under
// the file length limit.

extension JournalEvent {
    static func decodeCardCommitTrailerMissing(_ reader: PayloadReader) throws -> JournalEvent {
        .cardCommitTrailerMissing(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            commit: try reader.require("commit")
        )
    }

    static func decodeCardCommitTrailersUnread(_ reader: PayloadReader) throws -> JournalEvent {
        .cardCommitTrailersUnread(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            commit: try reader.require("commit"),
            reason: try reader.require("reason")
        )
    }

    static func decodeCardReportedCommitUnresolved(_ reader: PayloadReader) throws -> JournalEvent {
        .cardReportedCommitUnresolved(
            cardID: try reader.int64("card_id"),
            issueID: try reader.require("issue_id"),
            attemptID: try reader.int64("attempt_id"),
            reported: try reader.require("reported"),
            resolved: try reader.require("resolved")
        )
    }
}
