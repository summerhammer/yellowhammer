import Domain
import Foundation
import Journal

extension PulseSnapshot {
    /// The Night's ``NightOutcome``, folded once from the Night's own events (the unstamped invocation failures
    /// `pulseEvents` also returns are dropped). The Cards, Issues and Attempts the events name are looked up in the
    /// Journal here so the fold itself stays pure; one the Journal no longer holds keeps the id its event carries.
    static func nightOutcome(
        _ night: NightRecord, journal: JournalStore, events: [JournalEventRecord]
    ) throws -> NightOutcome {
        let nightEvents = events.filter { $0.nightID == night.id }
        var cardNames: [Int64: String] = [:]
        for cardID in NightOutcome.referencedCardIDs(nightEvents) {
            guard let card = try cardOrNil(journal, id: cardID),
                  let name = card.issueIDForDisplay ?? card.issueKey, !name.isEmpty else { continue }
            cardNames[cardID] = name
        }
        var issueNames: [String: String] = [:]
        for issueID in NightOutcome.referencedIssueIDs(nightEvents) {
            let card = try journal.card(issueID: issueID)
            let name = try card.flatMap { $0.issueIDForDisplay ?? $0.issueKey }
                ?? journal.feature(issueID: issueID).flatMap { $0.issueIDForDisplay ?? $0.issueKey }
            if let name, !name.isEmpty { issueNames[issueID] = name }
        }
        var attemptRoutes: [Int64: String] = [:]
        for (cardID, attemptID) in NightOutcome.reclaimedAttemptIDs(nightEvents) {
            let history = try journal.attemptHistory(cardID: cardID)
            attemptRoutes[attemptID] = history.attempts.first { $0.id == attemptID }?.route.description
        }
        return NightOutcome(
            events: nightEvents, cardNames: cardNames, issueNames: issueNames, attemptRoutes: attemptRoutes
        )
    }

    private static func cardOrNil(_ journal: JournalStore, id: Int64) throws -> CardRecord? {
        do {
            return try journal.card(id: id)
        } catch JournalError.cardUnknown {
            return nil
        }
    }
}
