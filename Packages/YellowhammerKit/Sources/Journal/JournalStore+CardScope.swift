import Domain
import Foundation
import GRDB

extension JournalStore {
    /// The Card's declared scope: the paths it is authored to touch, in authored order. Empty when
    /// none is recorded.
    public func declaredScope(cardID: Int64) throws -> [String] {
        try read { db in
            try String.fetchAll(
                db,
                sql: "SELECT path FROM card_scope WHERE card_id = ? ORDER BY position",
                arguments: [cardID]
            )
        }
    }

    /// Records the Card's declared scope, replacing whatever was recorded before it in one write
    /// transaction.
    public func recordDeclaredScope(cardID: Int64, paths: [String]) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM card_scope WHERE card_id = ?", arguments: [cardID])
            for (position, path) in paths.enumerated() {
                try db.execute(
                    sql: "INSERT INTO card_scope (card_id, position, path) VALUES (?, ?, ?)",
                    arguments: [cardID, position, path]
                )
            }
        }
    }
}
