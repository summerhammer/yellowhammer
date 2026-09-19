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
}
