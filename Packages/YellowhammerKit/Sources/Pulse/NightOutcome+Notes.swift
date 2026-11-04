import Domain
import Foundation
import Journal

extension NightOutcome.Fold {
    /// The findings with no Card of their own. A swept leftover process is the system working as designed and is
    /// not recorded here; only one left running unattributed is.
    mutating func addNote(_ record: JournalEventRecord) {
        switch record.event {
        case .cardCommitTrailersUnread(let cardID, let issueID, _, _, _):
            Self.note(&outcome.unreadTrailers, record, detail: name(cardID, issueID))
        case .leftoverProcessRecorded(_, _, _, _, _, let command, .leftRunningUnattributed, _):
            Self.note(&outcome.unattributedLeftovers, record, detail: command)
        case .managedBlockOverBudget(let issueID, _, _):
            Self.note(&outcome.overBudgetBlocks, record, detail: names.issues[issueID] ?? issueID)
        case .expiredCardLeasesSwept(_, let reclaimed) where !reclaimed.isEmpty:
            Self.note(
                &outcome.sweptCardLeases, record, details: reclaimed.map { names.cards[$0] ?? String($0) },
                count: reclaimed.count
            )
        default:
            break
        }
    }

    static func note(
        _ note: inout NightOutcome.Note?, _ record: JournalEventRecord, detail: String
    ) {
        Self.note(&note, record, details: [detail], count: 1)
    }

    static func note(
        _ note: inout NightOutcome.Note?, _ record: JournalEventRecord, details: [String], count: Int
    ) {
        guard var existing = note else {
            note = NightOutcome.Note(details: details, occurrence: Occurrence(record, count: count))
            return
        }
        existing.occurrence.add(record, count: count)
        for detail in details where !existing.details.contains(detail) { existing.details.append(detail) }
        note = existing
    }
}
