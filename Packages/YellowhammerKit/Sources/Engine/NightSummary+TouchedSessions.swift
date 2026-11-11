import Domain
import Foundation
import Journal

extension NightSummary {
    /// Advisory checks made before worker resumes, in Journal order. Each line names the Work Card
    /// and Round; neither foreign turns nor an unreadable transcript changes resumption.
    public static func touchedSessionLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        try nightEvents(night: night, journal: journal).compactMap { record in
            let cardID: Int64
            let issueID: String
            let round: Int
            let detail: String
            switch record.event {
            case .agentSessionHadForeignTurns(let card, let issue, _, let number, _, _, _, _, _):
                (cardID, issueID, round) = (card, issue, number)
                detail = "its session was continued outside Yellowhammer"
            case .agentSessionCheckFailed(let card, let issue, _, let number, _, _, _):
                (cardID, issueID, round) = (card, issue, number)
                detail = "could not check its session for turns Yellowhammer did not write"
            default: return nil
            }
            let displayID = (try? journal.card(id: cardID).displayIdentifier) ?? issueID
            return "`\(displayID)`: \(detail) before Round \(round); resumed as usual"
        }
    }
}
