import Domain
import Foundation
import Journal
import Repositories

/// Reclaims every Card Lease a dead run left expired, at build Act start, before Worktree reconciliation
/// (loop-state/reclaim-an-expired-lease, P8.10). Per Card of the in-flight Cycle whose Lease is held by
/// another, expired run: claims it under this run, runs the Pre-Reclaim Quiescence Gate over the Card's
/// held Worktree (``ProcessFencer``), defensively classifies the dead run's open Attempt (if any) from a
/// result file, the event log, or Crashed-Unknown, reposts the Card from In Progress back to Ready (or
/// Done, on a classified success) with a crash comment through the Outbox, appends `.cardReclaimed`, and
/// releases the Lease again — leaving the Card free for this Act's own lanes to pick up. Always appends
/// `.expiredCardLeasesSwept`, even when nothing was reclaimed. See `ExpiredLeaseSweep+Reclaim.swift` for
/// the reclaim sequence itself.
public struct ExpiredLeaseSweep: Sendable {
    public let journal: JournalStore
    public let runID: RunID
    /// Stamped on every event this sweep appends: the build Act.
    public let act: Act
    public let nightID: Int64?
    public let clock: @Sendable () -> Date
    /// The Pre-Reclaim Quiescence Gate: terminates any lingering process still holding the Card's
    /// Worktree before classification or repost ever look at it.
    public let fencer: ProcessFencer
    /// The board projection, when a Board is bound: the crash repost goes through it, like every other
    /// board-writing Card transition. Nil transitions on the Journal alone.
    public let projection: BoardStateProjection?
    /// Locates the dead run's last-attempted pass's result file, when this invocation can read one. Nil
    /// (a rehearsal Night's own binding included) falls straight to the event log and Crashed-Unknown.
    public let resultReader: (any RunResultReading)?

    public init(
        journal: JournalStore,
        runID: RunID,
        act: Act,
        nightID: Int64?,
        clock: @escaping @Sendable () -> Date = { Date() },
        fencer: ProcessFencer = ProcessFencer(),
        projection: BoardStateProjection? = nil,
        resultReader: (any RunResultReading)? = nil
    ) {
        self.journal = journal
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.clock = clock
        self.fencer = fencer
        self.projection = projection
        self.resultReader = resultReader
    }

    /// Reclaims every expired Card Lease of `cycleID`'s Cards (`featureID` is their Feature, for the
    /// Worktree lookup), releasing each straight back afterward. Always appends
    /// `.expiredCardLeasesSwept`, even when nothing was reclaimed.
    @discardableResult
    public func sweep(featureID: Int64, cycleID: Int64) async throws -> [Int64] {
        let now = clock()
        var reclaimed: [Int64] = []
        for card in try journal.cards(cycleID: cycleID) {
            guard let lease = try journal.currentCardLease(cardID: card.id) else { continue }
            guard lease.runID != runID, !lease.isHeld(at: now) else { continue }
            let previousRunID = lease.runID
            let expiredAt = lease.expiresAt
            // `claimCardLease` records `.cardLeaseReclaimed` itself when it takes over a different,
            // expired run's lease, which is exactly the precondition just checked above.
            let claim = try journal.claimCardLease(cardID: card.id, runID: runID, now: now)
            switch claim {
            case .claimed, .reclaimed:
                reclaimed.append(card.id)
                try await reclaim(
                    card: card, featureID: featureID, previousRunID: previousRunID, expiredAt: expiredAt, now: now
                )
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
