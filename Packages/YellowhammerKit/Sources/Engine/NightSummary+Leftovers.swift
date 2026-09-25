import Domain
import Foundation
import Journal

// The Night Summary's `**Leftover processes:**` section (Normal-Exit Sweep Ruling, issue #175): one
// line per Card whose runs left processes this Night, naming how many were swept (either layer) and
// how many were left running unattributed.

extension NightSummary {
    /// The `**Leftover processes:**` section: ONE line naming every Card whose runs left processes
    /// this Night, in first-seen order, each Card's clause giving its swept count
    /// (``LeftoverProcessDisposition/sweptByRunningSnapshot`` and
    /// ``LeftoverProcessDisposition/sweptByWorktreeFence`` together) and its left-running-unattributed
    /// count, each counted by distinct pid — either part omitted when zero, but a Card's clause never empty, e.g. `` "`ENG-1` 2
    /// swept, 1 left running unattributed; `ENG-4` 1 swept" ``. Empty when this Night recorded no
    /// `leftoverProcessRecorded` event. Not folded into ``touchedCardEventTypes``: a leftover process
    /// is reported here, not among the Cards touched this Night.
    public static func leftoverProcessLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var order: [String] = []
        // Distinct pids per Card: the fence runs after every pass, so a process left running across
        // several passes (an Operator's shell in the Worktree) is recorded once per pass but counted once.
        var swept: [String: Set<pid_t>] = [:]
        var unattributed: [String: Set<pid_t>] = [:]

        for record in try nightEvents(night: night, journal: journal) {
            guard case .leftoverProcessRecorded(_, let issueID, _, _, let pid, _, let disposition, _) = record.event
            else {
                continue
            }
            if swept[issueID] == nil, unattributed[issueID] == nil {
                order.append(issueID)
            }
            switch disposition {
            case .sweptByRunningSnapshot, .sweptByWorktreeFence:
                swept[issueID, default: []].insert(pid)
            case .leftRunningUnattributed:
                unattributed[issueID, default: []].insert(pid)
            }
        }

        guard !order.isEmpty else { return [] }
        let clauses = order.map { issueID -> String in
            var parts: [String] = []
            if let count = swept[issueID]?.count, count > 0 {
                parts.append("\(count) swept")
            }
            if let count = unattributed[issueID]?.count, count > 0 {
                parts.append("\(count) left running unattributed")
            }
            return "`\(issueID)` \(parts.joined(separator: ", "))"
        }
        return [clauses.joined(separator: "; ")]
    }
}
