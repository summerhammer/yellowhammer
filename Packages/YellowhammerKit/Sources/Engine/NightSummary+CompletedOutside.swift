import Domain
import Foundation
import Journal

// The Night Summary's `**Completed outside Yellowhammer:**` section (spec: morning-report/write-the-night-summary;
// ruling OQ199 item 9, 2026-11-08): each Work Card read as Operator Done, named once, on the Night it was read.

extension NightSummary {
    /// One line per Work Card read as Operator Done this Night — only `.cardOperatorDone` events carrying this
    /// Night's id, so nothing is standing — sorted by repository then authored order: the Card's name and the
    /// state the Operator's Done replaced (from the Card's latest such event this Night). A Card read twice
    /// this Night is named once. Empty when no Work Card was read as Operator Done this Night.
    public static func completedOutsideYellowhammerLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        let events = try nightEvents(night: night, journal: journal)
        var previousStates: [Int64: CardState] = [:]
        for record in events {
            guard case .cardOperatorDone(let cardID, _, let previousState, _, _) = record.event else { continue }
            previousStates[cardID] = previousState
        }
        var cards: [CardRecord] = []
        for cardID in previousStates.keys {
            cards.append(try journal.card(id: cardID))
        }
        cards.sort(by: authoredBefore)
        return cards.map { card in
            let previous = previousStates[card.id]?.rawValue ?? "unknown"
            return "\(cardName(card)) — moved to Done on the board by the Operator (was \(previous))."
        }
    }

    /// Repository, then authored order: the order ``touchedCards(events:journal:)`` sorts by.
    private static func authoredBefore(_ lhs: CardRecord, _ rhs: CardRecord) -> Bool {
        if lhs.repository != rhs.repository { return lhs.repository < rhs.repository }
        return lhs.authoredOrder < rhs.authoredOrder
    }
}
