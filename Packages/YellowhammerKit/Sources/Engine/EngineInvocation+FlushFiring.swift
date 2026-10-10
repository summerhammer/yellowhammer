import Domain
import Foundation
import Journal

/// A land Act started by one of the three flush firings after `night_end` (Transient Board Failure Ruling
/// 2026-10-09 item 6, as amended by the Build Firing Offset Ruling 2026-10-10 item 2). It runs the same
/// `yh land` as every land firing, so `EngineCommand` classifies it from the clock; here it does no Night
/// work — no `openNight`, mainline refresh, opening readiness, trigger, `LandAct` or Roll-up maintenance —
/// and only finishes what the Night's closing land left undone.
extension EngineInvocation {
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
    /// land would — close reason `night_end`, the Night Card completion through the Outbox, Kept in Flight
    /// reset, and the `closed` notification (a flush firing that closes a Night is its closing Act).
    private func closeOpenNightFromFlush(_ opened: NightRecord) async throws {
        var night = opened
        var nightCard: NightCardMaintenance?
        var outbox: Outbox?
        do {
            try await boardPreflight()
            (outbox, nightCard) = try await openNightCardIfNeeded(night: night)
            if outbox != nil {
                night = try journal.night(id: night.id) ?? night
            }
            try await closeNightIfNeeded(night, card: nightCard, outbox: outbox)
            appendClosing(.actEnded, night: night)
        } catch {
            await recordHalt(error, night: night, nightCard: nightCard, outbox: outbox)
            throw error
        }
    }

    /// The Night is already closed: deliver the Project's pending Outbox entries and post no notification —
    /// the closing Act has already said whether the completion is pending. A board that is still unreachable
    /// leaves the entries pending (this Outbox does not count the pass as an attempt); a failure of the
    /// firing itself is recorded as `FlushFiringRan`, not `ActIncomplete`, since the Night did not halt.
    private func deliverPendingFromFlush(_ night: NightRecord) async {
        guard let (_, card) = makeNightCardMaintenance(night: night) else {
            record(.nothingPending, detail: nil, night: night)
            return
        }
        do {
            let before = try journal.pendingOutboxEntries().count
            let report = try await card.deliverCompletion(night: night)
            let after = try journal.pendingOutboxEntries().count
            if before == 0 {
                record(.nothingPending, detail: nil, night: night)
            } else {
                // Recorded as delivered only when something was: an unreachable board delivers nothing.
                record(
                    report.applied.isEmpty ? .stillPending : .delivered,
                    detail: "\(report.applied.count) applied, \(after) of \(before) still pending", night: night
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
