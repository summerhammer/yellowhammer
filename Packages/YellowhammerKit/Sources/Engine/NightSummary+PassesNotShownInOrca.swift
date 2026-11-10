import Domain
import Foundation
import Journal

// The Night Summary's `**Passes not shown in Orca:**` section
// (story graph-execution/see-and-open-agent-sessions-in-orca, AC orca-unreachable):
// one line naming every Card that recorded an agentPassNotShownInOrca event this Night,
// in first-seen order, each once however many passes ran unseen, by the Card's display identifier.

extension NightSummary {
    /// The `**Passes not shown in Orca:**` section: ONE line naming every Card that
    /// recorded an ``JournalEvent/agentPassNotShownInOrca`` event this Night, in first-seen order,
    /// each once however many passes ran unseen, by the Card's display identifier (falling back to its
    /// issue id), followed by `: Orca was unreachable, ran unseen`. Empty when this Night recorded no such event.
    /// Not folded into ``touchedCardEventTypes``: reported here, not among Cards touched this Night.
    public static func passesNotShownInOrcaLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var order: [(cardID: Int64, issueID: String)] = []
        var seen: Set<Int64> = []

        for record in try nightEvents(night: night, journal: journal) {
            guard case .agentPassNotShownInOrca(let cardID, let issueID, _, _, _, _) = record.event else {
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

        return ["\(cardNames.joined(separator: ", ")): Orca was unreachable, ran unseen"]
    }
}
