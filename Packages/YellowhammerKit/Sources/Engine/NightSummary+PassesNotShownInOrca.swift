import Domain
import Foundation
import Journal

// The Night Summary's `**Passes not shown in Orca:**` section
// (story graph-execution/see-and-open-agent-sessions-in-orca, AC orca-unreachable;
// story morning-report/write-the-night-summary, AC orca-session-lines): one line per Work Card pass
// that recorded an agentPassNotShownInOrca event this Night, naming the Card and the pass.

extension NightSummary {
    /// The `**Passes not shown in Orca:**` section: one line per Work Card and pass that recorded an
    /// ``JournalEvent/agentPassNotShownInOrca`` event this Night, in first-seen order. The line names the
    /// Card by its display identifier (or its issue id when the Card is not found) and the pass:
    /// `` `ENG-1` · worker: not shown in Orca (Orca unreachable) ``. A pass that ran unseen in several
    /// Rounds or Attempts is named once. Empty when this Night recorded no such event.
    /// Not folded into ``touchedCardEventTypes``: reported here, not among Cards touched this Night.
    public static func passesNotShownInOrcaLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        struct CardPass: Hashable {
            let cardID: Int64
            let issueID: String
            let pass: RunPass
        }
        var order: [CardPass] = []
        var seen: Set<CardPass> = []

        for record in try nightEvents(night: night, journal: journal) {
            guard case .agentPassNotShownInOrca(let cardID, let issueID, _, let pass, _, _) = record.event else {
                continue
            }
            let item = CardPass(cardID: cardID, issueID: issueID, pass: pass)
            if seen.insert(item).inserted {
                order.append(item)
            }
        }

        var displayIDs: [Int64: String] = [:]
        return order.map { item in
            let displayID = displayIDs[item.cardID]
                ?? (try? journal.card(id: item.cardID).displayIdentifier)
                ?? item.issueID
            displayIDs[item.cardID] = displayID
            return "`\(displayID)` · \(item.pass.rawValue): not shown in Orca (Orca unreachable)"
        }
    }
}
