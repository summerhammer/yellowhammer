import Domain
import Foundation
import GRDB

/// A durable snapshot of one Feature's consecutive authoring faults.
public struct AuthoringFaultCount: Equatable, Sendable {
    public let count: Int
    public let lastReason: String
}

extension JournalStore {
    public func authoringFaultCount(feature: FeatureName) throws -> AuthoringFaultCount {
        try read { db in
            try Self.authoringFaultCount(db, feature: feature.rawValue)
        }
    }

    static func authoringFaultCount(_ db: Database, feature: String) throws -> AuthoringFaultCount {
        let row = try Row.fetchOne(
            db, sql: "SELECT * FROM authoring_fault WHERE feature_name = ? ORDER BY id DESC LIMIT 1",
            arguments: [feature]
        )
        return AuthoringFaultCount(count: row?["consecutive_faults"] ?? 0, lastReason: row?["reason"] ?? "")
    }

    /// Counts a whole rejected Route walk or permanently refused transaction exactly once. The event
    /// and counter commit together, after lease revalidation; replaying an operation never adds one.
    @discardableResult
    // swiftlint:disable:next function_parameter_count
    public func recordAuthoringFault(
        feature: FeatureName, reason: String, operationKey: String, event: JournalEvent,
        nightID: Int64, act: Act, runID: RunID, now: Date = Date()
    ) throws -> AuthoringFaultCount {
        let now = Self.stored(now)
        return try write { db in
            _ = try Self.revalidateActLease(db, runID: runID, now: now)
            guard try Int.fetchOne(db, sql: "SELECT 1 FROM authoring_fault WHERE operation_key = ?",
                                   arguments: [operationKey]) == nil else {
                return try Self.authoringFaultCount(db, feature: feature.rawValue)
            }
            let count = try Self.authoringFaultCount(db, feature: feature.rawValue).count + 1
            let stamp = EventStamp(act: act, runID: runID, nightID: nightID, now: now)
            let eventID = try Self.insertEvent(db, event, stamp: stamp)
            try db.execute(sql: """
                INSERT INTO authoring_fault
                (feature_name, operation_key, consecutive_faults, reason, night_id, event_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [feature.rawValue, operationKey, count, reason, nightID, eventID])
            return AuthoringFaultCount(count: count, lastReason: reason)
        }
    }

    /// Reads immutable fault history at a Night's event cutoff, so subsequent success cannot rewrite
    /// an older Night Summary. A successful transaction inserts its zero snapshot atomically.
    public func authoringFaultCount(feature: FeatureName, throughEventID: Int64) throws -> AuthoringFaultCount {
        try read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT * FROM authoring_fault WHERE feature_name = ? AND event_id <= ?
                ORDER BY id DESC LIMIT 1
                """, arguments: [feature.rawValue, throughEventID])
            return AuthoringFaultCount(count: row?["consecutive_faults"] ?? 0, lastReason: row?["reason"] ?? "")
        }
    }
}
