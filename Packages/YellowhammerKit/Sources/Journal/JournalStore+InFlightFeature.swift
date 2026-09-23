import Domain
import Foundation
import GRDB

// The unmerged-in-flight-Feature standing line (roadmap P12.1; spec: morning-report/write-the-night-
// summary): how many recorded Nights a Feature has held the in-flight slot, counted the same way as
// the un-adopted-Cards derivation — recorded Nights only, nothing derived from calendar dates.

extension JournalStore {
    /// The Night `featureID`'s selection recorded (`feature.selected_night_id`), or nil when the row
    /// itself is unreadable — the caller reads this as "the Night it entered flight is not recorded"
    /// rather than guessing.
    public func selectedNightID(featureID: Int64) throws -> Int64? {
        try read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT selected_night_id FROM feature WHERE id = ?", arguments: [featureID]
            ) else {
                return nil
            }
            return row["selected_night_id"]
        }
    }

    /// Nights elapsed from `selectedNightID`'s Night through `nightStart`, inclusive — both ends
    /// counted, and only recorded Nights counted, the same style `unadoptedNights(cardID:asOf:)` uses.
    /// Nil when `selectedNightID` does not resolve to a recorded Night.
    public func nightsHeld(selectedNightID: Int64, asOf nightStart: NightStart) throws -> Int? {
        try read { db in
            guard
                let selectedRow = try Row.fetchOne(
                    db, sql: "SELECT night_start FROM night WHERE id = ?", arguments: [selectedNightID]
                ),
                let selectedStart = NightStart(rawValue: selectedRow["night_start"])
            else {
                return nil
            }

            let nightRows = try Row.fetchAll(
                db,
                sql: "SELECT night_start FROM night WHERE project_id = ? ORDER BY night_start ASC",
                arguments: [projectID.rawValue]
            )
            return nightRows.reduce(into: 0) { count, row in
                guard let recordedStart = NightStart(rawValue: row["night_start"]) else { return }
                if recordedStart >= selectedStart, recordedStart <= nightStart {
                    count += 1
                }
            }
        }
    }
}
