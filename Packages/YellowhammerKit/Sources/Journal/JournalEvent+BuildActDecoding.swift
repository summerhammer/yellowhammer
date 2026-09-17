import Domain
import Foundation

// The build Act's own events' decode helpers, split out of JournalEvent+Decoding.swift (whose
// exhaustive switch still dispatches to them) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeExpiredCardLeasesSwept(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("reclaimed_card_ids")
        let reclaimedCardIDs: [Int64] = raw.isEmpty ? [] : try raw.split(separator: ",").map {
            guard let id = Int64($0) else { throw JournalError.eventUnreadable(id: reader.rowID) }
            return id
        }
        return .expiredCardLeasesSwept(cycleID: try reader.int64("cycle_id"), reclaimedCardIDs: reclaimedCardIDs)
    }

    static func decodeRepoLanesDerived(_ reader: PayloadReader) throws -> JournalEvent {
        let raw = try reader.require("lanes")
        let lanes = raw.isEmpty ? [] : raw.split(separator: ",").map(String.init)
        return .repoLanesDerived(cycleID: try reader.int64("cycle_id"), lanes: lanes)
    }

    static func decodeRepoLaneEnded(_ reader: PayloadReader) throws -> JournalEvent {
        .repoLaneEnded(
            repository: try reader.require("repository"),
            cardsRun: try reader.int("cards_run"),
            failure: reader.payload?["failure"],
            cardsSkipped: reader.payload?["cards_skipped"].flatMap(Int.init) ?? 0
        )
    }
}
