import Domain
import Foundation
import GRDB

extension JournalStore {
    /// Project-local account backoff survives Acts and Nights. Vendor reset text is a hint only:
    /// the engine uses a bounded 30-minute delay, never an ambiguous local wall-clock time.
    public func recordUsageLimit(
        route: Route, resetHint: String?, runID: RunID, act: Act, nightID: Int64?, now: Date = Date()
    ) throws {
        try append(
            .routeUsageLimited(route: route.description, cli: route.cli,
                               until: now.addingTimeInterval(30 * 60), resetHint: resetHint),
            act: act, runID: runID, nightID: nightID, now: now
        )
    }

    public func backingOffCLIs(asOf now: Date = Date()) throws -> Set<String> {
        try read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(payload, '$.cli') FROM event
                WHERE type = ? AND json_extract(payload, '$.until') > ?
                """, arguments: [JournalEventType.routeUsageLimited.rawValue, JournalStore.timestamp(now)])
            return Set(rows)
        }
    }
}
