import Domain
import Foundation

// The five worktree reconciliation events' decode helpers, split out of JournalEvent+Decoding.swift
// (whose exhaustive switch still dispatches to them) to keep that file under the file length limit.

extension JournalEvent {
    /// `lost_commit` and `lost_done_card_ids` (OQ133) are absent from events written before they existed
    /// and from a purge that lost nothing, so both are optional here.
    static func decodeWorktreeLost(_ reader: PayloadReader) throws -> JournalEvent {
        let rawLostDoneCardIDs = reader.payload?["lost_done_card_ids"] ?? ""
        let lostDoneCardIDs: [Int64] = try rawLostDoneCardIDs.split(separator: ",").map {
            guard let id = Int64($0) else { throw JournalError.eventUnreadable(id: reader.rowID) }
            return id
        }
        return .worktreeLost(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            worktreeID: try reader.require("worktree_id"),
            path: try reader.require("path"),
            pinnedCommit: reader.payload?["pinned_commit"],
            lostCommit: reader.payload?["lost_commit"],
            lostDoneCardIDs: lostDoneCardIDs
        )
    }

    static func decodeWorktreeFenced(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeFenced(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            path: try reader.require("path"),
            killed: try reader.int("killed")
        )
    }

    static func decodeWorktreeNotQuiescent(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeNotQuiescent(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            path: try reader.require("path"),
            remaining: try reader.int("remaining")
        )
    }

    static func decodeWorktreeWIPCommitted(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeWIPCommitted(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            wipCommit: try reader.require("wip_commit"),
            wipRef: try reader.require("wip_ref"),
            resetTo: reader.payload?["reset_to"]
        )
    }

    static func decodeWorktreeReconciliationFailed(_ reader: PayloadReader) throws -> JournalEvent {
        .worktreeReconciliationFailed(
            featureID: try reader.int64("feature_id"),
            repository: try reader.require("repository"),
            path: try reader.require("path"),
            reason: try reader.require("reason")
        )
    }
}
