import Domain
import GRDB

extension JournalStore {
    /// How many author Acts, other than the one run `excludingRunID` names, have started in `nightID`.
    ///
    /// The author trigger asks it to tell the Night's first author firing — the only one that runs while a
    /// Feature is in flight — from a periodic one. `EngineInvocation` appends `ActStarted` before it
    /// evaluates the trigger, so the invocation's own event is in the table already and is excluded by run.
    public func authorActStartedCount(nightID: Int64, excludingRunID: RunID) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM event
                WHERE type = ? AND act = ? AND night_id = ? AND (run_id IS NULL OR run_id != ?)
                """,
                arguments: [
                    JournalEventType.actStarted.rawValue, Act.author.rawValue, nightID, excludingRunID.rawValue
                ]
            ) ?? 0
        }
    }
}
