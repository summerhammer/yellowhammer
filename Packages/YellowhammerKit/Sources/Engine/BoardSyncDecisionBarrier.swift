import Domain
import Journal

/// A checkpoint may retain observations without authorizing decisions against an incomplete read.
/// Reporting already accepted facts can proceed, while Feature projections wait for reconciliation.
enum BoardSyncDecisionBarrier {
    static func isHeld(journal: JournalStore, runID: RunID) throws -> Bool {
        if try journal.boardSyncPoint()?.pass != nil { return true }
        let events = try journal.events(
            runID: runID, ofTypes: [.deltaReadCompleted, .deltaReadIncomplete, .rateBudgetExhausted, .actIncomplete]
        )
        let syncEvents = events.filter { record in
            if case .rateBudgetExhausted(let degradation, _) = record.event {
                // A refused mutation is retryable delivery, not an incomplete Delta Read.
                return degradation.hasPrefix("the Delta Read")
            }
            return true
        }
        guard let latest = syncEvents.last else { return false }
        return latest.type != .deltaReadCompleted
    }
}
