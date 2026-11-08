import Domain
import Foundation
import Journal

// The Night Summary's second Failure Notice source: a landing step the land Act recorded `failed`. A failed
// landing step is a Failure Notice but no Act failure (morning-report/disclose-a-failure#what-is-a-failure), so
// it never reaches ``ActFailures``, Pulse Health or `yh status`.
// draft-based: morning-report/write-the-night-summary#failure-line, disclose-a-failure#where (draft)

extension NightSummary {
    /// One failed landing step's identity: failures with one step, repository and detail are one notice.
    private struct LandingFailureKey: Hashable {
        let step: LandStep
        let repository: String
        let detail: String
    }

    private struct LandingFailure {
        let record: JournalEventRecord
        let runKey: String
    }

    /// What the notice of one step says. draft-based: morning-report/write-the-night-summary#failure-line,
    /// disclose-a-failure#where (draft)
    private struct LandingGuidance {
        let phrase: String
        let cause: String
        let next: String
        let mayDo: String
    }

    /// The failures of one notice: consecutive repeats of one identity, and the recovery that closed them.
    private struct LandingFailureGroup {
        let key: LandingFailureKey
        var failures: [LandingFailure]
        var recoveredAt: Date?
    }

    /// Folds the Night's failed landing steps into notices, flush firings excluded.
    private static func landingFailureGroups(events: [JournalEventRecord]) -> [LandingFailureGroup] {
        var groups: [LandingFailureGroup] = []
        var open: [LandingFailureKey: Int] = [:]
        for record in withoutFlushFirings(events) {
            switch record.event {
            case .landStep(let step, let repository, .failed, let detail):
                let key = LandingFailureKey(step: step, repository: repository ?? "", detail: detail ?? "")
                let failure = LandingFailure(record: record, runKey: record.runID?.rawValue ?? "event-\(record.id)")
                if let index = open[key] {
                    groups[index].failures.append(failure)
                } else {
                    open[key] = groups.count
                    groups.append(LandingFailureGroup(key: key, failures: [failure]))
                }
            case .landStep(let step, let repository, .completed, _):
                for (key, index) in open where key.step == step && key.repository == (repository ?? "") {
                    groups[index].recoveredAt = record.occurredAt
                    open[key] = nil
                }
            case .cycleLanded:
                for index in open.values { groups[index].recoveredAt = record.occurredAt }
                open.removeAll()
            default:
                break
            }
        }
        return groups
    }

    /// The headline of one landing step notice.
    static func landingHeadline(for step: LandStep, repository: String) -> String {
        let guidance = landingGuidance(for: step)
        return repository.isEmpty
            ? "Landing failed: \(guidance.phrase)" : "Landing `\(repository)` failed: \(guidance.phrase)"
    }

    /// The headlines of this Night's unrecovered failed landing steps.
    static func unrecoveredLandingHeadlines(events: [JournalEventRecord]) -> [String] {
        landingFailureGroups(events: events)
            .filter { $0.recoveredAt == nil }
            .map { landingHeadline(for: $0.key.step, repository: $0.key.repository) }
    }

    /// The Failure Notices of this Night's failed landing steps, flush firings excluded. Repeats of one identity
    /// (step, repository, detail) fold into one line until a recovery: a later completed landing of the same step
    /// and repository, or the Cycle landing. A failure after that recovery starts a new line
    /// (morning-report/write-the-night-summary#one-notice-per-run). Unrecovered lines first, then the recovered
    /// ones, each with ` — recovered at hh:mm` (a recovered failure keeps its own line).
    static func landingFailureLines(
        events: [JournalEventRecord], calendar: Calendar, projectID: ProjectID
    ) -> [String] {
        var unrecovered: [String] = []
        var recovered: [String] = []
        for group in landingFailureGroups(events: events) {
            let line = landingFailureLine(group.key, group.failures, calendar: calendar, projectID: projectID)
            if let at = group.recoveredAt {
                recovered.append("\(line) — recovered at \(clock(at, calendar))")
            } else {
                unrecovered.append(line)
            }
        }
        return unrecovered + recovered
    }

    private static func landingFailureLine(
        _ key: LandingFailureKey, _ group: [LandingFailure], calendar: Calendar, projectID: ProjectID
    ) -> String {
        guard let first = group.first, let last = group.last else { return "" }
        let guidance = landingGuidance(for: key.step)
        let headline = landingHeadline(for: key.step, repository: key.repository)
        let runs = Set(group.map(\.runKey)).count
        let from = clock(first.record.occurredAt, calendar)
        let until = clock(last.record.occurredAt, calendar)
        let span = runs > 1 ? " · \(runs) times, \(from)–\(until)" : ""
        let reason = key.detail.isEmpty ? "no reason was recorded" : oneLine(key.detail)
        return "**\(headline)**\(span) — cause: \(guidance.cause); \(reason). "
            + "Details: the comment on the Feature Card, and \(logPointer(.land, "land", projectID)). "
            + "Next: \(guidance.next). You may: \(guidance.mayDo)."
    }

    private static func landingGuidance(for step: LandStep) -> LandingGuidance {
        switch step {
        case .push:
            LandingGuidance(
                phrase: "the push", cause: "the push was refused or failed",
                next: "the next land firing retries the push",
                mayDo: "correct the credential or branch protection the reason names"
            )
        case .openPullRequest:
            LandingGuidance(
                phrase: "the pull request", cause: "the pull request did not open",
                next: "the next land firing retries", mayDo: "follow the route out on the Feature Card"
            )
        case .releaseWorktree:
            LandingGuidance(
                phrase: "the Worktree release", cause: "the Worktree was not released",
                next: "the Worktree stays held and the next land firing tries again",
                mayDo: "follow the route out on the Feature Card"
            )
        case .mergeTest:
            LandingGuidance(
                phrase: "the merge test", cause: "the merge test failed",
                next: "the next land firing tries again", mayDo: "see the merge test comment on the Feature Card"
            )
        case .verification, .returnFeature, .archiveCycle:
            LandingGuidance(
                phrase: "the \(step.rawValue) step", cause: "the step failed",
                next: "the next land firing retries", mayDo: "nothing until the next firing"
            )
        }
    }
}
