import Domain
import Foundation

// The Readiness Check's own events' decode helpers (P8.2), split out of JournalEvent+Decoding.swift
// (whose exhaustive switch still dispatches to them) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeReadinessCheckFailed(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("failures")
        let failures = raw.isEmpty ? [] : raw.components(separatedBy: "\u{1F}")
        return .readinessCheckFailed(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"), failures: failures
        )
    }

    static func decodeCardDiverged(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("changed_paths")
        let changedPaths = raw.isEmpty ? [] : raw.components(separatedBy: "\u{1F}")
        return .cardDiverged(
            cardID: try reader.int64("card_id"), issueID: try reader.require("issue_id"),
            repository: try reader.require("repository"), changedPaths: changedPaths
        )
    }
}
