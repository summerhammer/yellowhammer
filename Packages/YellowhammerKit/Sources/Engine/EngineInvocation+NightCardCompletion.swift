import Domain
import Foundation
import Journal

extension EngineInvocation {
    /// After the Act that closes the Night has tried to deliver the Night Card's completion: re-reads each
    /// of the entries `acceptCompletion` returned and, if any is still pending (the board could not be
    /// reached), records `.nightCardCompletionDeferred` and writes one line to the Act's log. The Outbox
    /// replays them on a later Act; this only makes the gap visible. Entries are re-read from the Journal
    /// rather than taken from the delivery report, because a pass that defers its first entry stops, and
    /// the report never mentions the second. Best-effort: it never fails the Act.
    func recordDeferredCompletion(entries: [OutboxEntry], night: NightRecord) {
        let pending = entries.compactMap { try? journal.outboxEntry(clientID: $0.clientID) }
            .filter { $0.state == .pending }
        guard let first = pending.first, let issueID = night.nightCardIssueID else { return }
        let ids = pending.map(\.id)
        let reason = first.lastError ?? "still pending"
        _ = try? journal.append(
            .nightCardCompletionDeferred(issueID: issueID, entryIDs: ids, reason: reason),
            act: act, runID: runID, nightID: night.id
        )
        let list = ids.map(String.init).joined(separator: ", ")
        actLog(
            "Night Card completion deferred: Outbox entries \(list) still pending (\(reason)); "
                + "a later Act delivers them"
        )
    }

    /// Ensures the Project's Night Card is live when a board is wired, replacing an archived card. Split out of
    /// `runUnderLease` to keep that function under the function body length limit; the caller re-reads
    /// the Night afterwards, since `open` may have recorded its Night Card issue id.
    func openNightCardIfNeeded(night: NightRecord) async throws -> (Outbox?, NightCardMaintenance?) {
        guard let board else { return (nil, nil) }
        var boxed = Outbox(
            journal: journal, board: board.writing, reading: board.reading, runID: runID, act: act, nightID: night.id,
            installation: board.installation, scrub: narrativeScrub
        ) { [outboxKill] in outboxKill?.interrupt($0) }
        boxed.transientRetry = outboxTransientRetry
        let maintenance = NightCardMaintenance(
            journal: journal, outbox: boxed, provisioning: board.provisioning, bounds: nightCardBounds
        )
        let opening = try await maintenance.open(night: night)
        if !night.isOpen, case .opened = opening {
            _ = try await maintenance.acceptCompletion(night: night)
            _ = try await maintenance.deliverCompletion(night: night)
        }
        return (boxed, maintenance)
    }
}
