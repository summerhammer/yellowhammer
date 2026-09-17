import Domain
import Foundation
import Journal

/// The Journal half of loop-state/reclaim-an-expired-lease (P8.10): at build Act start, before
/// Worktree reconciliation, every Card of the in-flight Cycle whose Card-scoped Lease a dead run left
/// expired is reclaimed under this run. Classification, fencing and the repost-to-Ready comment are
/// P8.10's own later work and slot in between the reclaim and the release below; until then, a
/// reclaimed Card's Lease is simply released again, leaving it free for the next Act to pick up.
public struct ExpiredLeaseSweep: Sendable {
    public let journal: JournalStore
    public let runID: RunID
    /// Stamped on every event this sweep appends: the build Act.
    public let act: Act
    public let nightID: Int64?
    public let clock: @Sendable () -> Date

    public init(
        journal: JournalStore,
        runID: RunID,
        act: Act,
        nightID: Int64?,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.journal = journal
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.clock = clock
    }

    /// Reclaims every expired Card Lease of `cycleID`'s Cards, releasing each straight back afterward.
    /// Always appends `.expiredCardLeasesSwept`, even when nothing was reclaimed.
    @discardableResult
    public func sweep(cycleID: Int64) throws -> [Int64] {
        let now = clock()
        var reclaimed: [Int64] = []
        for card in try journal.cards(cycleID: cycleID) {
            guard let lease = try journal.currentCardLease(cardID: card.id) else { continue }
            guard lease.runID != runID, !lease.isHeld(at: now) else { continue }
            // `claimCardLease` records `.cardLeaseReclaimed` itself when it takes over a different,
            // expired run's lease, which is exactly the precondition just checked above.
            let claim = try journal.claimCardLease(cardID: card.id, runID: runID, now: now)
            switch claim {
            case .claimed, .reclaimed:
                reclaimed.append(card.id)
                try journal.releaseCardLease(cardID: card.id, runID: runID)
            case .held:
                continue
            }
        }
        try journal.append(
            .expiredCardLeasesSwept(cycleID: cycleID, reclaimedCardIDs: reclaimed),
            act: act, runID: runID, nightID: nightID, now: now
        )
        return reclaimed
    }
}
