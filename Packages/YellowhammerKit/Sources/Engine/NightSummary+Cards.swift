import Domain
import Foundation
import Journal

// The Night Summary's `**Cards:**` and `**Dispositions:**` sections (roadmap P12.1): one line per Card
// touched this Night, and the Blocked/Waiting-on-You count plus recurrence-vs-first-occurrence over
// those same Cards. Never cost.

extension NightSummary {
    /// One line per Card touched this Night, sorted by repository then authored order: the Card's
    /// identifier (linked to its issue when the URL is known) and where it stands at the end of the Night,
    /// then each Attempt of it touched this Night — its ordinal in the Card's whole history, route, result,
    /// Check result (worded by `AttemptAccount.checkResult`, from the Attempt's `checkRan` events, never
    /// from Rounds) and Rounds with their lenses. Empty when no Card was touched.
    public static func cardLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        let events = try nightEvents(night: night, journal: journal)
        let cards = try touchedCards(events: events, journal: journal)
        return try cards.map { card in
            try cardLine(card: card, events: events, journal: journal)
        }
    }

    private static func cardLine(
        card: CardRecord, events: [JournalEventRecord], journal: JournalStore
    ) throws -> String {
        let name = cardName(card)
        let attemptIDs = touchedAttemptIDs(cardID: card.id, events: events)
        guard !attemptIDs.isEmpty else {
            return "\(name) — \(card.state.rawValue) · no Attempt this Night."
        }
        let history = try journal.attemptHistory(cardID: card.id)
        // Built from the events already read: `nightEvents` is read once per section, by design.
        let checkRuns: [(cardID: Int64, run: CheckRunRecord)] = events.compactMap { record in
            guard case .checkRan(let cardID, _, _, _, _, _, _) = record.event,
                let run = CheckRunRecord(record) else { return nil }
            return (cardID, run)
        }
        let cardRuns = checkRuns.filter { $0.cardID == card.id }.map(\.run)
        // The ordinal is the Attempt's place in the Card's whole history, not among this Night's Attempts.
        let attempts = history.attempts.enumerated().filter { attemptIDs.contains($0.element.id) }
            .sorted { $0.element.id < $1.element.id }
            .map { attemptSummary(ordinal: $0.offset + 1, $0.element, checkRuns: cardRuns) }
        return "\(name) — \(card.state.rawValue) · " + attempts.joined(separator: " · ")
    }

    /// Attempt ids named by this Card's `attemptEnded`, `routeRetried` or `checkRan` events this Night.
    private static func touchedAttemptIDs(cardID: Int64, events: [JournalEventRecord]) -> [Int64] {
        var seen: Set<Int64> = []
        var order: [Int64] = []
        for record in events {
            let match: Int64?
            switch record.event {
            case .attemptEnded(let recordCardID, _, let attemptID, _, _, _) where recordCardID == cardID:
                match = attemptID
            case .routeRetried(let recordCardID, _, let attemptID, _, _) where recordCardID == cardID:
                match = attemptID
            case .checkRan(let recordCardID, _, let attemptID, _, _, _, _) where recordCardID == cardID:
                match = attemptID
            default:
                match = nil
            }
            if let match, seen.insert(match).inserted {
                order.append(match)
            }
        }
        return order
    }

    /// The `**Dispositions:**` section: the Blocked/Waiting-on-You count over Cards touched this
    /// Night, then which of this Night's `failureCauseRecorded` events on those Cards were a
    /// recurrence (`recurrenceCount > 1`) versus a first occurrence, each naming its Card, then each
    /// Work Card removed from the board this Night (``removedCardLines(events:journal:)``). Empty when
    /// no Card was touched or removed.
    public static func dispositionLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        let events = try nightEvents(night: night, journal: journal)
        let cards = try touchedCards(events: events, journal: journal)
        let removed = try removedCardLines(events: events, journal: journal)
        guard !cards.isEmpty else { return removed }
        let touchedIDs = Set(cards.map(\.id))
        let blocked = cards.filter { $0.state == .blocked }.count
        let waiting = cards.filter { $0.state == .waitingOnYou }.count
        var lines = ["\(blocked) Blocked, \(waiting) Waiting on You"]
        for record in events {
            guard case .failureCauseRecorded(let cardID, _, _, _, let recurrenceCount) = record.event,
                touchedIDs.contains(cardID) else { continue }
            let kind = recurrenceCount > 1 ? "recurrence" : "first occurrence"
            lines.append("\(cardName(try journal.card(id: cardID))) — \(kind).")
        }
        for record in events {
            guard case .cardRunStep(let cardID, _, .operatorAborted, let detail) = record.event else { continue }
            let attempt = detail.map { $0.replacingOccurrences(of: "attempt ", with: "") } ?? "?"
            let name = cardName(try journal.card(id: cardID))
            lines.append(
                "\(name) was stopped by the Operator: Attempt \(attempt) aborted, consuming no Attempt " +
                    "and excluding no Route. It stays Blocked (`operator abort`) until re-ready."
            )
        }
        return lines + removed
    }

    /// One line per Work Card whose issue was trashed, or archived while in play, this Night (OQ142),
    /// however many Acts saw it: named once, with how it was removed, and whether the board restored it
    /// before the Night ended.
    static func removedCardLines(events: [JournalEventRecord], journal: JournalStore) throws -> [String] {
        var order: [Int64] = []
        var how: [Int64: String] = [:]
        var restored: Set<Int64> = []
        for record in events {
            switch record.event {
            case .cardRemovedFromBoard(let cardID, _, let removal):
                if how.updateValue(removal, forKey: cardID) == nil { order.append(cardID) }
                restored.remove(cardID)
            case .cardRestoredToBoard(let cardID, _, _) where how[cardID] != nil:
                restored.insert(cardID)
            default:
                continue
            }
        }
        return try order.map { cardID in
            let card = try journal.card(id: cardID)
            let name = cardName(card)
            let removal = how[cardID] ?? CardRemoval.trashed.rawValue
            let after = restored.contains(cardID)
                ? "The issue was restored this Night, and the Card is back in play as it stood."
                : "It is set aside with nothing posted to it, and resumes as it stood if the issue is restored."
            return "\(name) was \(removal) on the board. \(after)"
        }
    }
}
