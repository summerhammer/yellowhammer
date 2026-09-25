import Foundation
import GRDB

extension JournalStore {
    /// Whether this Journal currently holds a live Lease of either kind: the Card-scoped `lease`
    /// (V1) or the Project-scoped `act_lease` (V2). Read-only, so it is safe on a store opened with
    /// ``openReadOnly(at:projectID:)``. `launchd` runs `yh` from inside the app bundle, so an update
    /// that replaced the bundle out from under a live Lease would corrupt whatever Act holds it —
    /// this is what the updater's install gate checks before proceeding.
    public func holdsLiveLease(now: Date = Date()) throws -> Bool {
        let now = JournalStore.stored(now)
        return try read { db in
            if try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM lease WHERE expires_at > ? LIMIT 1",
                arguments: [JournalStore.timestamp(now)]
            ) != nil {
                return true
            }
            if try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM act_lease WHERE expires_at > ? LIMIT 1",
                arguments: [JournalStore.timestamp(now)]
            ) != nil {
                return true
            }
            return false
        }
    }
}
