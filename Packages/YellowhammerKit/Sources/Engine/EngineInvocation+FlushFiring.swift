import Domain
import Foundation
import Journal

/// A land Act started by one of the three flush firings after `night_end` (Transient Board Failure Ruling
/// 2026-10-09 item 6, as amended by the Build Firing Offset Ruling 2026-10-10 item 2). It runs the same
/// `yh land` as every land firing. The first such firing when the closing land never ran
/// ends the hold, evaluates land, maintains Roll-ups and closes the existing Night.
/// Subsequent firings only finish the outstanding completion delivery.
extension EngineInvocation {
    /// A closing land that has acquired the Lease consumes this Night's hold-ending firing,
    /// even if board preflight or later work throws before the Night closes.
    func endHoldAtClosingFiring(_ night: NightRecord) throws {
        guard act == .land && closesNight else { return }
        // Recover a span whose last Card transition was durable before a build died.
        _ = try LandHold.refresh(journal: journal, nightID: night.id, runID: runID,
                                 schedule: landHoldSchedule, now: Date())
        try journal.endNightHold(nightID: night.id, runID: runID)
    }

    /// The Act's life under the Lease: a flush firing's, or any other Act's.
    func runUnderLeaseOrFlush() async throws {
        if isFlushFiring {
            try await runFlushFiring()
        } else {
            try await runUnderLease()
        }
    }

    /// The flush firing's life under the Act Lease, which `run()` has already claimed (a held Lease stands
    /// the firing down there, and the next flush retries).
    func runFlushFiring() async throws {
        // The Night is looked up, never opened: opening one for a Night that never started would create a
        // Night Card for it, and the absence of a Night Card is the "never started" signal.
        guard let night = try journal.night(nightStart: nightStart) else {
            _ = try? journal.append(.flushFiringRan(outcome: .noNight, detail: nil), act: act, runID: runID)
            actLog("Flush firing: Night \(nightStart) was never recorded, so there is nothing to close or deliver")
            return
        }
        _ = try? journal.append(.actStarted, act: act, runID: runID, nightID: night.id)
        if night.isOpen {
            try await closeOpenNightFromFlush(night)
        } else {
            await deliverPendingFromFlush(night)
        }
    }

    /// The closing land died, halted or stood down on the Lease: close the Night exactly as the closing
    /// land would — close reason `night_end`, the Night Card completion through the Outbox, and the `closed`
    /// notification (a flush firing that closes a Night is its closing Act).
    private func closeOpenNightFromFlush(_ opened: NightRecord) async throws {
        let mayLand = try !journal.hasNightHoldEnded(nightID: opened.id)
        if mayLand {
            _ = try LandHold.refresh(journal: journal, nightID: opened.id, runID: runID,
                                     schedule: landHoldSchedule, now: Date())
            try journal.endNightHold(nightID: opened.id, runID: runID)
        }
        var night = opened
        var nightCard: NightCardMaintenance?
        var outbox: Outbox?
        do {
            try await boardPreflight(night: night)
            (outbox, nightCard) = try await openNightCardIfNeeded(night: night)
            if outbox != nil {
                night = try journal.night(id: night.id) ?? night
            }
            // Only the first post-close firing ends the hold. A closing land that already
            // fired and died has consumed that opportunity; this flush then only closes.
            if mayLand {
                let outcome = try ActTriggerPredicate.evaluate(
                    act: act, trigger: trigger, journal: journal, nightID: night.id, runID: runID,
                    landHoldSchedule: landHoldSchedule
                )
                try journal.endNightHold(nightID: night.id, runID: runID)
                switch outcome {
                case .met:
                    var context = ActContext(
                        act: act, mode: mode, trigger: trigger, runID: runID, journal: journal, night: night,
                        outbox: outbox, nightCard: nightCard, board: board,
                        workspace: workspace, repositories: repositories, operatorIdentity: operatorIdentity
                    )
                    context.landHoldSchedule = landHoldSchedule
                    context.unansweredNightsMax = nightCardBounds.unansweredNightsMax
                    try await withLeaseHeartbeat(
                        every: leasePolicy.heartbeatDuration,
                        beat: { try journal.heartbeatActLease(runID: runID, policy: leasePolicy) },
                        body: { [context] in try await work(context) }
                    )
                case .notMet(let reason):
                    try journal.append(.actIdle(reason: reason), act: act, runID: runID, nightID: night.id)
                }
                try await maintainRollUps(night: night, outbox: outbox)
            }
            try await closeNightIfNeeded(night, card: nightCard, outbox: outbox)
            appendClosing(.actEnded, night: night)
        } catch {
            await recordHalt(error, night: night, nightCard: nightCard, outbox: outbox)
            throw error
        }
    }

    /// The Night is already closed: deliver the Project's pending Outbox entries and post no notification —
    /// the closing Act has already said whether the completion is pending. A completion the closing Act never
    /// accepted (its Night closed in the Journal, then a Linear read failed before the Night Card completion
    /// reached the Outbox) is accepted here first, so the flush has something to deliver. A board that is
    /// still unreachable leaves the entries pending (this Outbox does not count the pass as an attempt); a
    /// failure of the firing itself is recorded as `FlushFiringRan`, not `ActIncomplete`, since the Night did
    /// not halt.
    private func deliverPendingFromFlush(_ night: NightRecord) async {
        guard let (_, card) = makeNightCardMaintenance(night: night) else {
            record(.nothingPending, detail: nil, night: night)
            return
        }
        do {
            var accepted = false
            // Only a Night closed at `night_end` is completed: one that opened and died, or whose Project was
            // removed, keeps its open Night Card.
            if night.closeReason == .nightEnd, try !card.isCompletionAccepted(night: night) {
                _ = try await card.acceptCompletion(night: night)
                accepted = true
            }
            let before = try journal.pendingOutboxEntries().count
            let prefix = accepted ? "completion accepted; " : ""
            let report = try await card.deliverCompletion(night: night)
            let after = try journal.pendingOutboxEntries().count
            if before == 0 {
                record(.nothingPending, detail: nil, night: night)
            } else {
                // Recorded as delivered only when something was: an unreachable board delivers nothing.
                record(
                    report.applied.isEmpty ? .stillPending : .delivered,
                    detail: "\(prefix)\(report.applied.count) applied, \(after) of \(before) still pending",
                    night: night
                )
            }
            appendClosing(.actEnded, night: night)
        } catch {
            record(.failed, detail: String(describing: error), night: night)
            actLog("Flush firing failed on closed Night \(nightStart): \(error)")
            // The Act ended, though it did not do what it came for; its own failure is the event above.
            appendClosing(.actEnded, night: night)
        }
    }

    private func record(_ outcome: FlushFiringOutcome, detail: String?, night: NightRecord) {
        _ = try? journal.append(
            .flushFiringRan(outcome: outcome, detail: detail), act: act, runID: runID, nightID: night.id
        )
    }
}
