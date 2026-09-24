import Domain
import Foundation
import GRDB

// Explicit Project removal (roadmap P13.5; spec risks OQ52(1)): refused while an Act of this Project
// holds an active Act Lease; otherwise closes any open Night with reason `.projectRemoved`, decommissions
// the in-flight slot (a Cycle open with no verdict yet), and releases the Worktrees the caller names.
// Removal is not an Act — it holds no Act Lease of its own (`act_lease.act`'s CHECK admits only
// author/build/land) — so this refuses on any *other* held lease rather than revalidating one of its own.
// Never deletes anything; the Journal file is kept.

/// Everything one Project removal write needs, bundled so
/// ``JournalStore/recordProjectRemoval(_:runID:now:)`` stays under the parameter-count limit.
public struct NewProjectRemoval: Sendable {
    /// The in-flight Feature Issue commented on before removal, nil when none was in flight. Recorded
    /// as-is in the ``JournalEvent/projectRemoved(featureIssueID:removedWorktrees:keptWorktrees:)``
    /// payload; this write does not itself determine it.
    public let featureIssueID: String?
    /// The Worktree ids removal discarded (or found already-Worktree-quiescent and safe to discard) and
    /// wants released. An id already released is skipped; an unknown id throws
    /// ``JournalError/worktreeUnknown(id:)``.
    public let releasedWorktreeIDs: [Int64]

    public init(featureIssueID: String?, releasedWorktreeIDs: [Int64]) {
        self.featureIssueID = featureIssueID
        self.releasedWorktreeIDs = releasedWorktreeIDs
    }
}

/// What ``JournalStore/recordProjectRemoval(_:runID:now:)`` did.
public struct ProjectRemovalRecord: Equatable, Sendable {
    /// Every open Night this call closed, ascending. At most one in practice — a Journal holds at most
    /// one open Night (``JournalStore/currentNight()``) — but every one found open is closed.
    public let closedNightIDs: [Int64]
    /// The in-flight Cycle this call archived, nil when none was open or it was already archived.
    public let archivedCycleID: Int64?
    /// The in-flight Feature this call released (`feature.released_at`), nil when none was open or it
    /// was already released.
    public let releasedFeatureID: Int64?
    /// The repositories whose held Worktree this call released.
    public let removedWorktrees: [String]
    /// The repositories whose held Worktree this call left in place (a dirty Worktree in rehearsal, say).
    public let keptWorktrees: [String]
}

extension JournalStore {
    /// Records explicit Project removal (roadmap P13.5; spec risks OQ52(1)). One write transaction:
    ///
    /// 1. Reads the `act_lease` row; if it exists and is still held at `now`, throws
    ///    ``JournalError/projectRemovalRefused(holder:)`` and writes nothing. An expired lease does not
    ///    refuse — that run is dead, or asleep past its TTL, the same rule ``claimActLease`` uses.
    /// 2. Closes every open Night with reason `.projectRemoved`, appending `.nightClosed(reason:)` per
    ///    Night, stamped act nil.
    /// 3. Decommissions the in-flight slot when a Cycle is open: archives it (`archived_at` only, never
    ///    `closed_by`) and sets `feature.released_at` if unset — the same shape
    ///    ``settleFeatureReleased(_:runID:act:nightID:now:)`` writes for a *released* settle value.
    /// 4. Sets `released_at` on the Worktree rows `removal.releasedWorktreeIDs` names, skipping ones
    ///    already released.
    /// 5. Appends `.projectRemoved(featureIssueID:removedWorktrees:keptWorktrees:)`, stamped act nil,
    ///    `nightID` the closed open Night's id when there was one, else nil.
    ///
    /// Idempotent in effect: a second call with nothing open closes nothing and archives nothing, though
    /// it still appends a `.projectRemoved` event — removal is recorded as having run, not merely as
    /// having changed something. Never deletes anything; the Journal file is kept.
    @discardableResult
    public func recordProjectRemoval(
        _ removal: NewProjectRemoval, runID: RunID, now: Date = Date()
    ) throws -> ProjectRemovalRecord {
        let now = JournalStore.stored(now)
        return try write { db in
            if let holder = try Self.fetchActLease(db), holder.isHeld(at: now) {
                throw JournalError.projectRemovalRefused(holder: holder)
            }

            let closedNightIDs = try Self.closeEveryOpenNight(db, projectID: projectID, runID: runID, now: now)
            let (archivedCycleID, releasedFeatureID) = try Self.decommissionInFlightSlot(db, now: now)
            let (removedWorktrees, keptWorktrees) = try Self.releaseNamedWorktrees(
                db, worktreeIDs: removal.releasedWorktreeIDs, now: now
            )

            let stamp = EventStamp(act: nil, runID: runID, nightID: closedNightIDs.first, now: now)
            _ = try Self.insertEvent(
                db,
                .projectRemoved(
                    featureIssueID: removal.featureIssueID,
                    removedWorktrees: removedWorktrees,
                    keptWorktrees: keptWorktrees
                ),
                stamp: stamp
            )

            return ProjectRemovalRecord(
                closedNightIDs: closedNightIDs,
                archivedCycleID: archivedCycleID,
                releasedFeatureID: releasedFeatureID,
                removedWorktrees: removedWorktrees,
                keptWorktrees: keptWorktrees
            )
        }
    }

    /// Closes every open Night of `projectID` with reason `.projectRemoved`, appending `.nightClosed`
    /// per Night stamped act nil. Returns the closed Night ids, ascending — the order
    /// ``Night/fetchOpenNights(_:projectID:)`` returns them in.
    private static func closeEveryOpenNight(
        _ db: Database, projectID: ProjectID, runID: RunID, now: Date
    ) throws -> [Int64] {
        let openNights = try Self.fetchOpenNights(db, projectID: projectID)
        var closedNightIDs: [Int64] = []
        for night in openNights {
            _ = try Self.close(db, night: night, reason: .projectRemoved, now: now)
            let stamp = EventStamp(act: nil, runID: runID, nightID: night.id, now: now)
            _ = try Self.insertEvent(db, .nightClosed(reason: .projectRemoved), stamp: stamp)
            closedNightIDs.append(night.id)
        }
        return closedNightIDs
    }

    /// Archives the in-flight Cycle (if one is open) and releases its Feature — the same shape
    /// ``settleFeatureReleased(_:runID:act:nightID:now:)`` writes. Returns the archived Cycle id and
    /// released Feature id, each nil when there was nothing to do.
    private static func decommissionInFlightSlot(_ db: Database, now: Date) throws -> (Int64?, Int64?) {
        let openCycleIDs = try Int64.fetchAll(db, sql: "SELECT id FROM cycle WHERE archived_at IS NULL")
        guard openCycleIDs.count <= 1 else {
            throw JournalError.multipleOpenCycles
        }
        guard let cycleID = openCycleIDs.first else {
            return (nil, nil)
        }
        guard
            let cycleRow = try Row.fetchOne(db, sql: "SELECT feature_id FROM cycle WHERE id = ?", arguments: [cycleID])
        else {
            throw JournalError.cycleUnknown(cycleID: cycleID)
        }
        let featureID: Int64 = cycleRow["feature_id"]
        let timestamp = JournalStore.timestamp(now)

        let archived = try Self.archiveCycleIfUnarchived(db, cycleID: cycleID, timestamp: timestamp)

        guard
            let featureRow = try Row.fetchOne(
                db, sql: "SELECT released_at FROM feature WHERE id = ?", arguments: [featureID]
            )
        else {
            throw JournalError.featureUnknown(featureID: featureID)
        }
        var releasedFeatureID: Int64?
        if (featureRow["released_at"] as String?) == nil {
            try db.execute(sql: "UPDATE feature SET released_at = ? WHERE id = ?", arguments: [timestamp, featureID])
            releasedFeatureID = featureID
        }
        return (archived ? cycleID : nil, releasedFeatureID)
    }

    /// Sets `released_at` on `worktreeIDs`, skipping ones already released; an unknown id throws
    /// ``JournalError/worktreeUnknown(id:)``. Returns the repositories released by this call and the
    /// repositories left held afterward — the Project's every held Worktree minus the ones this call
    /// released.
    private static func releaseNamedWorktrees(
        _ db: Database, worktreeIDs: [Int64], now: Date
    ) throws -> (removed: [String], kept: [String]) {
        let timestamp = JournalStore.timestamp(now)
        var removedWorktrees: [String] = []
        var releasedIDs: Set<Int64> = []
        for worktreeID in worktreeIDs {
            guard let existing = try Self.fetchWorktree(db, id: worktreeID) else {
                throw JournalError.worktreeUnknown(id: worktreeID)
            }
            if existing.releasedAt == nil {
                try db.execute(
                    sql: "UPDATE worktree SET released_at = ? WHERE id = ?", arguments: [timestamp, worktreeID]
                )
            }
            removedWorktrees.append(existing.repository)
            releasedIDs.insert(worktreeID)
        }

        let heldRows = try Row.fetchAll(
            db, sql: "SELECT id, repository FROM worktree WHERE released_at IS NULL ORDER BY id ASC"
        )
        let keptWorktrees: [String] = heldRows.compactMap { row in
            let id: Int64 = row["id"]
            guard !releasedIDs.contains(id) else { return nil }
            return row["repository"]
        }
        return (removedWorktrees, keptWorktrees)
    }
}
