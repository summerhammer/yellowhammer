import Domain
import Foundation
import GRDB

extension JournalStore {
    /// Project-local account backoff survives Acts and Nights. Vendor reset text is a hint only:
    /// the engine honours a hint that names its own zone, never an ambiguous local wall-clock
    /// time, and otherwise uses a bounded 30-minute delay (`UsageLimitReset`).
    public func recordUsageLimit(
        route: Route, resetHint: String?, runID: RunID, act: Act, nightID: Int64?, now: Date = Date()
    ) throws {
        try append(
            .routeUsageLimited(route: route.description, cli: route.cli,
                               until: UsageLimitReset.until(resetHint: resetHint, now: now),
                               resetHint: resetHint),
            act: act, runID: runID, nightID: nightID, now: now
        )
    }

    /// A backoff within `UsageLimitReset.cadenceGrace` of its end already counts as over.
    public func backingOffCLIs(asOf now: Date = Date()) throws -> Set<String> {
        let effectiveNow = now.addingTimeInterval(UsageLimitReset.cadenceGrace)
        return try read { db in
            let rows = try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(payload, '$.cli') FROM event
                WHERE type = ? AND json_extract(payload, '$.until') > ?
                """, arguments: [JournalEventType.routeUsageLimited.rawValue, JournalStore.timestamp(effectiveNow)])
            return Set(rows)
        }
    }
}
