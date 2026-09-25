import Domain
import Foundation

// A small read query for the Journal half of loop-state/reclaim-an-expired-lease (P8.10), split out
// to keep JournalStore+Events.swift under the file length limit.

extension JournalStore {
    /// Every `.cardReclaimed` event stamped with `nightID`, in append order: what one Night's build Acts
    /// reclaimed from a dead run's expired Card Leases, for the Night Summary (P12.1) to read. No other
    /// Project's Journal ever holds these rows — the Journal is scoped to one Project.
    public func reclaimedCards(nightID: Int64) throws -> [JournalEventRecord] {
        try events(ofType: .cardReclaimed).filter { $0.nightID == nightID }
    }

    /// The cause the dead run recorded when the engine stopped it and left `cardID`'s Lease to expire
    /// (``CardRunStep/leaseLeftToExpire``, OQ92): the `detail` of the last such step for `runID`, or a
    /// fallback account when the step carried none. `nil` when the run never recorded one — the wording
    /// stays exactly as today (a crash, not an engine stop). Used by the Expired Lease Sweep and the
    /// Night Summary, both from this one source.
    public func engineStopCause(cardID: Int64, runID: RunID) throws -> String? {
        var last: String??
        for record in try events(ofType: .cardRunStep) where record.runID == runID {
            guard case .cardRunStep(let recordCardID, _, let step, let detail) = record.event,
                recordCardID == cardID, step == .leaseLeftToExpire
            else { continue }
            last = detail
        }
        guard let found = last else { return nil }
        return found ?? "no cause recorded"
    }
}
