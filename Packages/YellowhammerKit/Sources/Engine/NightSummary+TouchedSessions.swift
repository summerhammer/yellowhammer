import Domain
import Foundation
import Journal

// The Night Summary's `**Sessions with turns Yellowhammer did not write:**` section
// (story graph-execution/see-and-open-agent-sessions-in-orca, AC touched-session):
// one line naming every Card that recorded an agentSessionHadForeignTurns event this Night,
// in first-seen order, each once however many Rounds found turns, by the Card's display identifier.

extension NightSummary {
    /// The `**Sessions with turns Yellowhammer did not write:**` section: ONE line naming every Card that
    /// recorded an ``JournalEvent/agentSessionHadForeignTurns`` event this Night, in first-seen order,
    /// each once however many Rounds found turns, by the Card's display identifier (falling back to its
    /// issue id), followed by `: resumed as usual`. Empty when this Night recorded no such event.
    /// Not folded into ``touchedCardEventTypes``: reported here, not among Cards touched this Night.
    public static func touchedSessionLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var order: [(cardID: Int64, issueID: String)] = []
        var seen: Set<Int64> = []

        for record in try nightEvents(night: night, journal: journal) {
            guard case .agentSessionHadForeignTurns(let cardID, let issueID, _, _, _) = record.event else {
                continue
            }
            if seen.insert(cardID).inserted {
                order.append((cardID, issueID))
            }
        }

        guard !order.isEmpty else { return [] }

        let cardNames = order.map { item -> String in
            let displayID = (try? journal.card(id: item.cardID).displayIdentifier) ?? item.issueID
            return "`\(displayID)`"
        }

        return ["\(cardNames.joined(separator: ", ")): resumed as usual"]
    }
}
