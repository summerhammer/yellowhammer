import Domain
import Foundation
import Journal

/// Computes the Night Summary (roadmap P12.1; spec: morning-report/write-the-night-summary) from one
/// Night's Journal events alone — nothing here reads the clock, and nothing here reads a sibling
/// Project's Journal. `NightCardMaintenance.acceptCompletion` renders the result through
/// `NightCardBlock.completed`.
///
/// Split across extensions to keep each file under the length limit:
/// `NightSummary+Verdict.swift` (the constant-time `**Verdict:**` line),
/// `NightSummary+Cards.swift` (`**Cards:**` and `**Dispositions:**`),
/// `NightSummary+PullRequests.swift` (`**Pull requests:**` and `**Answers on landed Cards:**`).
public enum NightSummary {
    /// The event types that count as a Card being "touched" this Night, for the `**Cards:**` and
    /// `**Dispositions:**` sections: any card-scoped event with this Night's id.
    static let touchedCardEventTypes: Set<JournalEventType> = [
        .attemptEnded, .checkRan, .cardRunStep, .cardStateTransitioned, .routeRetried, .cardReclaimed
    ]

    /// This Night's events, read once and reused by every section — the Night Summary never issues a
    /// second `events()` read per section.
    static func nightEvents(night: NightRecord, journal: JournalStore) throws -> [JournalEventRecord] {
        try journal.events().filter { $0.nightID == night.id }
    }

    /// The Card id a touched-card event names, or nil for an event that is not card-scoped in the way
    /// the `**Cards:**`/`**Dispositions:**` sections care about.
    static func cardID(for event: JournalEvent) -> Int64? {
        switch event {
        case .attemptEnded(let cardID, _, _, _, _, _),
            .checkRan(let cardID, _, _, _, _, _),
            .cardRunStep(let cardID, _, _, _),
            .cardStateTransitioned(let cardID, _, _, _, _, _),
            .routeRetried(let cardID, _, _, _, _),
            .cardReclaimed(let cardID, _, _, _, _, _):
            return cardID
        default:
            return nil
        }
    }

    /// Every Card touched this Night (any event in ``touchedCardEventTypes``), sorted by repository
    /// then authored order — the stable order the `**Cards:**` and `**Dispositions:**` sections render
    /// in.
    static func touchedCards(events: [JournalEventRecord], journal: JournalStore) throws -> [CardRecord] {
        var seen: Set<Int64> = []
        var order: [Int64] = []
        for record in events where touchedCardEventTypes.contains(record.type) {
            guard let id = cardID(for: record.event) else { continue }
            if seen.insert(id).inserted { order.append(id) }
        }
        let cards = try order.map { try journal.card(id: $0) }
        return cards.sorted { lhs, rhs in
            lhs.repository == rhs.repository
                ? lhs.authoredOrder < rhs.authoredOrder
                : lhs.repository < rhs.repository
        }
    }
}
