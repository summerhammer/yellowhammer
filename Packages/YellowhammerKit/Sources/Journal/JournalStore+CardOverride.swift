import Domain
import GRDB

extension JournalStore {
    /// The Card's `Card override:` lines as the Operator last saved them, in order; empty when the
    /// description held none, or only the empty form (roadmap P22.7). Malformed and duplicated lines are
    /// here exactly as written: judging them is ``CardOverrideField/reading(of:)``'s.
    public func cardOverrideLines(cardID: Int64) throws -> [String] {
        try read { db in
            let held = try String.fetchOne(db, sql: "SELECT card_override FROM card WHERE id = ?", arguments: [cardID])
            return held?.components(separatedBy: "\n") ?? []
        }
    }

    /// Records the lines the Operator's description holds, replacing whatever was held. The empty form on
    /// its own is the same as no line, so it is held as none. Returns whether the held value changed.
    @discardableResult
    public func recordCardOverrideLines(cardID: Int64, lines: [String]) throws -> Bool {
        let canonical = lines == [CardOverrideField.emptyLine] ? [] : lines
        let value = canonical.isEmpty ? nil : canonical.joined(separator: "\n")
        return try write { db in
            let held = try String.fetchOne(db, sql: "SELECT card_override FROM card WHERE id = ?", arguments: [cardID])
            guard held != value else { return false }
            try db.execute(sql: "UPDATE card SET card_override = ? WHERE id = ?", arguments: [value, cardID])
            return true
        }
    }
}
