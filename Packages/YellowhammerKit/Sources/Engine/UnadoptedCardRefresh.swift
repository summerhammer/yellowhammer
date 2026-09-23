import Domain
import Foundation
import Journal

/// Re-renders every un-adopted Card's Managed Block header at Night completion (roadmap P12.1), so its
/// "un-adopted for N Nights" figure never disagrees with the Night Summary's standing line — the
/// figure changes every Night whether or not the Card was touched. A refresh failure never fails the
/// Night's completion: the caller wraps this in `try?`, and each Card's own failure is skipped rather
/// than stopping the rest.
public enum UnadoptedCardRefresh {
    /// Claims each un-adopted Card's Lease, re-renders and conditionally posts its Managed Block
    /// (`ManagedBlockMaintenance.maintain`, hash-skipped when nothing changed), and releases the Lease
    /// — the claim → post → release pattern `ExpiredLeaseSweep`/`WaitingOnYouReplies` use, because an
    /// Outbox write carrying a `cardID` is silently deferred (`cardLeaseNotHeld`) without it. A Card
    /// whose Lease another live run holds is skipped: the next Night refreshes it.
    public static func refresh(
        night: NightRecord, journal: JournalStore, outbox: Outbox, runID: RunID
    ) async throws {
        for unadopted in try journal.unadoptedCards(asOf: night.nightStart) {
            try? await refreshOne(unadopted.card, journal: journal, outbox: outbox, runID: runID)
        }
    }

    private static func refreshOne(
        _ card: CardRecord, journal: JournalStore, outbox: Outbox, runID: RunID
    ) async throws {
        switch try journal.claimCardLease(cardID: card.id, runID: runID) {
        case .held:
            return
        case .claimed, .reclaimed:
            break
        }
        do {
            let current = try journal.card(id: card.id)
            let brief = ArchitecturalBrief(
                prose: try journal.architecturalBriefProse(cardID: current.id) ?? "",
                transcriptions: try journal.transcriptionBlocks(cardID: current.id).map(\.block)
            )
            let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox)
            _ = try await maintenance.maintain(card: current, brief: brief)
        } catch {
            _ = try? journal.releaseCardLease(cardID: card.id, runID: runID)
            throw error
        }
        _ = try journal.releaseCardLease(cardID: card.id, runID: runID)
    }
}
