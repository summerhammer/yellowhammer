import Domain
import Foundation
import Journal

// The Night Summary's `**Cards:**` and `**Dispositions:**` sections (roadmap P12.1): one line per Card
// touched this Night, and the Blocked/Waiting-on-You count plus recurrence-vs-first-occurrence over
// those same Cards. Never cost.

extension NightSummary {
    /// One line per Card touched this Night, sorted by repository then authored order: issue id,
    /// route(s) this Night used, Check result (model-alone worded like `CardManagedBlock`'s
    /// `AttemptAccount`), and Rounds with their lenses. Empty when no Card was touched.
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
        let attemptIDs = touchedAttemptIDs(cardID: card.id, events: events)
        guard !attemptIDs.isEmpty else {
            return "`\(card.issueID)` — no Attempt this Night."
        }
        let history = try journal.attemptHistory(cardID: card.id)
        let attempts = history.attempts.filter { attemptIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let routes = attempts.map { "\($0.route.cli)/\($0.route.model)" }.joined(separator: ", ")
        let checks = attempts.map(checkSummary).joined(separator: "; ")
        let rounds = attempts.map(roundsSummary).joined(separator: "; ")
        return "`\(card.issueID)` — route: \(routes) · check: \(checks) · rounds: \(rounds)"
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
            case .checkRan(let recordCardID, _, let attemptID, _, _, _) where recordCardID == cardID:
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

    private static func checkSummary(_ attempt: AttemptRecord) -> String {
        if attempt.checkDeclaredNone {
            return "green came from a model alone (`check = none`)"
        }
        if let checkRound = attempt.rounds.last(where: { $0.lens == .check }) {
            return checkRound.verdict
        }
        return "not recorded"
    }

    private static func roundsSummary(_ attempt: AttemptRecord) -> String {
        guard !attempt.rounds.isEmpty else { return "none" }
        return attempt.rounds.map { "\($0.lens.rawValue)(\($0.verdict))" }.joined(separator: ", ")
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
            guard case .failureCauseRecorded(let cardID, let issueID, _, _, let recurrenceCount) = record.event,
                touchedIDs.contains(cardID) else { continue }
            let kind = recurrenceCount > 1 ? "recurrence" : "first occurrence"
            lines.append("`\(issueID)` — \(kind).")
        }
        for record in events {
            guard case .cardRunStep(_, let issueID, .operatorAborted, let detail) = record.event else { continue }
            let attempt = detail.map { $0.replacingOccurrences(of: "attempt ", with: "") } ?? "?"
            lines.append(
                "`\(issueID)` was stopped by the Operator: Attempt \(attempt) aborted, consuming no Attempt " +
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
            let name = card.issueIDForDisplay ?? card.issueID
            let removal = how[cardID] ?? CardRemoval.trashed.rawValue
            let after = restored.contains(cardID)
                ? "The issue was restored this Night, and the Card is back in play as it stood."
                : "It is set aside with nothing posted to it, and resumes as it stood if the issue is restored."
            return "`\(name)` was \(removal) on the board. \(after)"
        }
    }
}
