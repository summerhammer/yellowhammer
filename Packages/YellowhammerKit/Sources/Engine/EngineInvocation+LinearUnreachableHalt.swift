import Domain
import Foundation
import Journal

/// A halt whose cause is Linear being unreachable pages the Operator starting at the 2nd consecutive
/// such halt of the Night, once per outage (re-posting if a post fails), and always on the Night-closing
/// Act (Transient Board Failure Ruling 2026-10-09 items 9-15, K = 2; morning-report/notify-the-operator-of-exceptions).
/// Every Act is a separate process, so the count is derived from the Journal at halt time: nothing is held in memory.
extension EngineInvocation {
    /// How many consecutive board-unreachable halts it takes to page the Operator (item 11).
    static let linearUnreachablePagingThreshold = 2

    /// This Act's board-unreachable halt, and where it stands in this Night's run of them.
    struct LinearUnreachableHalt {
        /// The consecutive board-unreachable halts of this Night including this Act's; nil when the
        /// Journal could not be read, in which case the Operator is paged rather than left unaware.
        var consecutive: Int?
        /// Whether no earlier halted notice of this outage has posted successfully; true when no
        /// notice has posted yet or when the Journal could not be read.
        var noticeUnposted = true
    }

    /// What one Act did about Linear, as its Journal events record it.
    struct ActLinearOutcome {
        var reached = false
        var unreachableHalt = false
        var authorizationHalt = false
    }

    /// When `error` is a board-unreachable halt, appends `.linearUnreachableHalted` and counts this Night's
    /// consecutive ones. Called before `.actIncomplete`, so the event precedes it; nil for every other error.
    func recordLinearUnreachableHalt(_ error: any Error, night: NightRecord) -> LinearUnreachableHalt? {
        guard error.isLinearUnreachable else { return nil }
        _ = try? journal.append(.linearUnreachableHalted, act: act, runID: runID, nightID: night.id)
        return evaluateLinearUnreachableHalt(night: night)
    }

    /// Evaluates the consecutive board-unreachable halts and whether earlier eligible Acts of the current
    /// outage failed to deliver their halted notice.
    func evaluateLinearUnreachableHalt(night: NightRecord) -> LinearUnreachableHalt {
        guard let outageRuns = currentOutageRunIDs(night: night) else {
            return LinearUnreachableHalt(consecutive: nil, noticeUnposted: true)
        }
        let earlierThresholdRuns = outageRuns
            .dropFirst(Self.linearUnreachablePagingThreshold - 1)
            .filter { $0 != runID }
        let noticeUnposted = allDeliveryFailed(for: Array(earlierThresholdRuns), night: night)
        return LinearUnreachableHalt(consecutive: outageRuns.count, noticeUnposted: noticeUnposted)
    }

    /// Whether every earlier Act in `runs` recorded a `.notificationDeliveryFailed(notification: "halted", ...)`
    /// event in this Night. True when `runs` is empty, or when the Journal cannot be read.
    private func allDeliveryFailed(for runs: [RunID], night: NightRecord) -> Bool {
        guard !runs.isEmpty else { return true }
        guard let failureRecords = try? journal.events(ofType: .notificationDeliveryFailed) else {
            return true
        }
        let failedRunIDs = Set(
            failureRecords.filter { record in
                guard record.nightID == night.id, record.runID != nil else { return false }
                if case .notificationDeliveryFailed(let notification, _) = record.event {
                    return notification == "halted"
                }
                return false
            }.compactMap(\.runID)
        )
        return runs.allSatisfy { failedRunIDs.contains($0) }
    }

    /// Walks this Night's Acts in order (items 9-10): an Act that ends in a board-unreachable halt
    /// increments the count, even when it reached Linear earlier in the same Act; any other Act that reached
    /// Linear resets it to 0; an Act that made no Linear request does neither, and neither does an
    /// authorization halt (item 14). Several failed requests in one Act count once, because an Act is one run.
    /// Reads only this Night's events.
    func consecutiveLinearUnreachableHalts(night: NightRecord) -> Int? {
        currentOutageRunIDs(night: night)?.count
    }

    /// The run IDs of the trailing run of consecutive board-unreachable halts in this Night.
    func currentOutageRunIDs(night: NightRecord) -> [RunID]? {
        guard let outcomes = try? actOutcomes(night: night) else { return nil }
        var outageRuns: [RunID] = []
        for (runID, outcome) in outcomes where !outcome.authorizationHalt {
            if outcome.unreachableHalt {
                outageRuns.append(runID)
            } else if outcome.reached {
                outageRuns.removeAll()
            }
        }
        return outageRuns
    }

    /// What each Act of this Night did about Linear, in the order the Acts first recorded it.
    private func actOutcomes(night: NightRecord) throws -> [(runID: RunID, outcome: ActLinearOutcome)] {
        var records: [JournalEventRecord] = []
        for type in [JournalEventType.linearReached, .linearUnreachableHalted, .linearAuthorizationHalted] {
            records += try journal.events(ofType: type).filter { $0.nightID == night.id && $0.runID != nil }
        }
        records.sort { $0.id < $1.id }

        var order: [RunID] = []
        var outcomes: [RunID: ActLinearOutcome] = [:]
        for record in records {
            guard let run = record.runID else { continue }
            if outcomes[run] == nil { order.append(run) }
            switch record.event {
            case .linearReached: outcomes[run, default: ActLinearOutcome()].reached = true
            case .linearUnreachableHalted: outcomes[run, default: ActLinearOutcome()].unreachableHalt = true
            case .linearAuthorizationHalted: outcomes[run, default: ActLinearOutcome()].authorizationHalt = true
            default: break
            }
        }
        return order.compactMap { run in outcomes[run].map { (run, $0) } }
    }

    /// The halted notice for a board-unreachable halt (items 11-13, 15).
    ///
    /// The Night-closing Act always posts, whatever the count (item 12): when it halted before closing the
    /// Night the notice says the Night is not closed and its Night Card is not updated yet; when it had
    /// already closed the Night, `.closed` / `.closedCompletionPending` has said so and the ordinary halted
    /// notice follows. Any other Act posts from the threshold onward until one notice has posted successfully:
    /// not the 1st, and not again after a successful post. A halt that does not post still writes its halted
    /// comment on the Night Card through the Outbox (item 13: the halt stays recorded), and does not fall
    /// back to OQ71's `.haltedUnrecorded` (item 15).
    func notifyLinearUnreachableHalted(
        _ halt: LinearUnreachableHalt, reason: String, night: NightRecord,
        nightCard: NightCardMaintenance?, outbox: Outbox?
    ) async {
        let closingAct = (closesNight || isFlushFiring) && night.isOpen
        let nightStillOpen = closingAct && ((try? journal.night(id: night.id))?.isOpen ?? true)
        if nightStillOpen {
            await recordHaltedCommentOnly(reason: reason, night: night, nightCard: nightCard, outbox: outbox)
            await notify(
                .haltedNightOpen(reason: Self.collapsed(reason)), notification: "halted", night: night
            )
        } else if closingAct || halt.consecutive.map({
            $0 >= Self.linearUnreachablePagingThreshold && halt.noticeUnposted
        }) ?? true {
            await notifyHalted(reason: reason, night: night, nightCard: nightCard, outbox: outbox)
        } else {
            await recordHaltedCommentOnly(reason: reason, night: night, nightCard: nightCard, outbox: outbox)
        }
    }
}
