import Domain
import Foundation
import Journal

// The Night Summary's `**Pull requests:**` and `**Answers on landed Cards:**` sections (roadmap
// P12.1).

extension NightSummary {
    /// Per repository, the pull requests recorded with `night_id` = this Night, flagged `Partial
    /// Landing` when their Feature's Cycle has lane holes; on a rehearsal Night, an
    /// `.openPullRequest`/`.rehearsalBoundary` `landStep` renders "not opened — rehearsal". Then each
    /// "not published" report made this Night (OQ191; ``UnpublishedCommitsReport``), at Verification time
    /// or at release, once each: a note, never a failure. Then each Feature Branch the pull request read found more
    /// than one pull request for this Night, once each (``multiplePullRequestLine(_:)``). Empty when none of these
    /// happened this Night.
    public static func pullRequestLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for pullRequest in try journal.pullRequests(nightID: night.id) {
            let partial = try isPartialLanding(featureID: pullRequest.featureID, journal: journal)
            let target = pullRequest.url ?? pullRequest.number.map { "#\($0)" } ?? "no url recorded"
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
        for record in events {
            if let report = UnpublishedCommitsReport.text(of: record.event), !lines.contains(report) {
                lines.append(report)
            }
        }
        for record in events {
            if let line = multiplePullRequestLine(record.event), !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }

    /// The note for a Feature Branch with more than one pull request (spec: morning-report/write-the-night-summary
    /// `#pull-request-read-notes`, OQ190 item 13): the branch and its pull requests. Reported, never a gate input;
    /// nil for any other event.
    static func multiplePullRequestLine(_ event: JournalEvent) -> String? {
        guard case .multiplePullRequestsObserved(let repository, let branch, let numbers) = event else { return nil }
        let named = numbers.map { "#\($0)" }.joined(separator: ", ")
        return "`\(repository)`: Feature Branch `\(branch)` has more than one pull request: \(named)."
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
