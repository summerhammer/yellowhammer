import GRDB

extension JournalStore {
    /// Whether a retry began in the Card run that ended its predecessor. Used only to reconstruct
    /// the incoming hand-over of an empty usage-limited Attempt; no new state is recorded.
    public func attemptRetriedInSameRun(attemptID: Int64, after priorAttemptID: Int64) throws -> Bool {
        try read { db in
            try Bool.fetchOne(
                db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM event AS retry JOIN event AS ending ON retry.run_id = ending.run_id
                    WHERE retry.type = ? AND ending.type = ?
                      AND json_extract(retry.payload, '$.attempt_id') = ?
                      AND json_extract(ending.payload, '$.attempt_id') = ?
                )
                """,
                arguments: [
                    JournalEventType.routeRetried.rawValue, JournalEventType.attemptEnded.rawValue,
                    String(attemptID), String(priorAttemptID)
                ]
            ) ?? false
        }
    }
}
