import Domain
import Foundation
import GRDB

// The reads the Act trigger predicates are evaluated from. They answer two questions and no others:
// has this Project any Card left to work, and is there a Feature in flight whose Cycle is finished.
extension JournalStore {
    /// How many of this Project's Cards are unfinished, in any Cycle.
    ///
    /// Project-wide, because the author trigger asks about the Project rather than about one Cycle.
    public func unfinishedCardCount() throws -> Int {
        try read { db in
            try Self.countUnfinished(
                try Row.fetchAll(db, sql: "SELECT id, state FROM card")
            )
        }
    }

    /// The open Cycle's id, or nil when no Feature is in flight.
    ///
    /// A Cycle is open until it is archived, and an open Cycle is exactly what a Feature still in
    /// flight looks like in the Journal — which is why no Feature state is read here.
    public func inFlightCycleID() throws -> Int64? {
        try read { db in
            let cycleIDs = try Int64.fetchAll(db, sql: "SELECT id FROM cycle WHERE archived_at IS NULL")
            switch cycleIDs.count {
            case 0:
                return nil
            case 1:
                return cycleIDs[0]
            default:
                // A Project has one in-flight Feature, so it has one open Cycle. Two means the
                // Journal is inconsistent, and guessing which one is in flight would be worse.
                throw JournalError.multipleOpenCycles
            }
        }
    }

    /// How many of one Cycle's Cards are unfinished. A Cancelled Card is not unfinished, which is
    /// what lets cancelling the last stuck Card release the Cycle to land.
    public func unfinishedCardCount(cycleID: Int64) throws -> Int {
        try read { db in
            try Self.countUnfinished(
                try Row.fetchAll(db, sql: "SELECT id, state FROM card WHERE cycle_id = ?", arguments: [cycleID])
            )
        }
    }

    /// Counts the unfinished Cards among `rows`, refusing any whose state is outside the vocabulary.
    ///
    /// Only the engine writes `card.state`, so an unrecognised value means the Journal is
    /// inconsistent. It is counted neither way: treating it as finished would let the land Act fire
    /// over work nobody could classify, and treating it as unfinished would grind on a Card no Act
    /// can act on. The row is named instead, and every trigger for this Project stops.
    private static func countUnfinished(_ rows: [Row]) throws -> Int {
        try rows.reduce(into: 0) { count, row in
            let rawState: String = row["state"]
            guard let state = CardState(rawValue: rawState) else {
                throw JournalError.unknownCardState(cardID: row["id"], state: rawState)
            }
            if state.isUnfinished {
                count += 1
            }
        }
    }
}
