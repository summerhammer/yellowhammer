import Domain
import Foundation
import Journal

// The Night Summary's `**Pull requests:**` and `**Answers on landed Cards:**` sections (roadmap
// P12.1).

extension NightSummary {
    /// Per repository, the pull requests recorded with `night_id` = this Night, flagged `Partial
    /// Landing` when their Feature's Cycle has lane holes; on a rehearsal Night, an
    /// `.openPullRequest`/`.rehearsalBoundary` `landStep` renders "not opened — rehearsal". Empty when
    /// neither happened this Night.
    public static func pullRequestLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for pullRequest in try journal.pullRequests(nightID: night.id) {
            let partial = try isPartialLanding(featureID: pullRequest.featureID, journal: journal)
            let target = pullRequest.url ?? "no url recorded"
            let flag = partial ? " (Partial Landing)" : ""
            lines.append("`\(pullRequest.repository)`: \(target)\(flag)")
        }
        let events = try nightEvents(night: night, journal: journal)
        for record in events {
            guard case .landStep(let step, let repository, let outcome, _) = record.event,
                step == .openPullRequest, outcome == .rehearsalBoundary, let repository
            else { continue }
            lines.append("`\(repository)`: not opened — rehearsal.")
        }
        return lines
    }

    private static func isPartialLanding(featureID: Int64, journal: JournalStore) throws -> Bool {
        guard let cycleID = try journal.cycleID(featureID: featureID) else { return false }
        return try !journal.laneHoles(cycleID: cycleID).isEmpty
    }

    /// One line per `waitingOnYouReplyBanked` event this Night, naming the Card whose answer arrived —
    /// appears only on the Night it was banked, never again, because the underlying event is appended
    /// once.
    public static func answerLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        try journal.events(ofType: .waitingOnYouReplyBanked).compactMap { record -> String? in
            guard record.nightID == night.id, case .waitingOnYouReplyBanked(_, let issueID, _) = record.event
            else { return nil }
            return "`\(issueID)`'s Waiting on You answer was banked on landing."
        }
    }
}
