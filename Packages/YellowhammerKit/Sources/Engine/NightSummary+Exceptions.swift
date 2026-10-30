import Domain
import Foundation
import Journal

// The Night Summary's `**Anomalies:**` extension, `**Crashes and reclaims:**` and `**Exceptions:**`
// sections (roadmap P12.1). A reclaimed Card is worded with the mandated phrase — "the Card is
// reclaimable, and no partial state was written as if it were complete" — never that it continues.

extension NightSummary {
    /// The `**Anomalies:**` section's lines: a Waiting on You Card the Delta Read found with no
    /// Journal record behind it, a broken Managed Block delimiter, and a Card that violates an
    /// authoring invariant. Empty when none of these happened this Night.
    public static func anomalyLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        func append(_ line: String) {
            guard seen.insert(line).inserted else { return }
            lines.append(line)
        }
        for record in try nightEvents(night: night, journal: journal) {
            switch record.event {
            case .waitingOnYouUnbacked(let issueID, _, _):
                append(
                    "`\(issueID)` was read in Waiting on You with no Journal record behind it; it was not dispatched."
                )
            case .managedBlockDelimiterBroken(let issueID):
                append(
                    "`\(issueID)`'s Managed Block delimiter was broken: the fenced block could not be " +
                        "located, so it was not rewritten this Night."
                )
            case .managedBlockOverBudget(let issueID, let length, let budget):
                append(
                    "`\(issueID)`'s description was not rewritten: it would be \(length) long against a " +
                        "description budget of \(budget)."
                )
            case .authoringInvariantBroken(_, let issueID, let reason):
                append("`\(issueID)` violates an authoring invariant: \(reason).")
            default:
                break
            }
        }
        return lines
    }

    /// The `**Crashes and reclaims:**` section: `nightOpenedAndDied`, `leaseReclaimed`,
    /// `cardLeaseReclaimed`/`cardReclaimed`, and `expiredCardLeasesSwept`. Empty when none of these
    /// happened this Night.
    public static func crashesAndReclaimsLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for record in try nightEvents(night: night, journal: journal) {
            switch record.event {
            case .nightOpenedAndDied(_, let nightStart):
                lines.append("Night `\(nightStart)` opened and died: it never completed, closed on resumption.")
            case .leaseReclaimed(let previousRunID, let previousAct, _):
                lines.append(
                    "The \(previousAct.rawValue) Act's Lease, held by run `\(previousRunID)`, was reclaimed: " +
                        "it expired."
                )
            case .cardLeaseReclaimed(let cardID, let previousRunID, _):
                let issueID = try journal.card(id: cardID).issueID
                lines.append(
                    "Card `\(issueID)`'s Lease, held by run `\(previousRunID)`, was reclaimed: the Card is " +
                        "reclaimable, and no partial state was written as if it were complete."
                )
            case .cardReclaimed(
                let cardID, let issueID, let previousRunID, let attemptID, let outcome, let routeExcluded
            ):
                var line = try reclaimedLine(
                    cardID: cardID, issueID: issueID, previousRunID: previousRunID, outcome: outcome,
                    journal: journal
                )
                if let attemptID, let outcome {
                    let excluded = routeExcluded ? "its Route excluded" : "its Route not excluded"
                    line += " Attempt `\(attemptID)` was classified \(outcome), \(excluded)."
                }
                lines.append(line)
            case .expiredCardLeasesSwept(_, let reclaimedCardIDs):
                guard !reclaimedCardIDs.isEmpty else { continue }
                let issueIDs = try reclaimedCardIDs.map { try journal.card(id: $0).issueID }
                lines.append(
                    "\(issueIDs.count) Card Lease\(issueIDs.count == 1 ? "" : "s") swept as expired: " +
                        "\(issueIDs.map { "`\($0)`" }.joined(separator: ", ")). Each is reclaimable, and no " +
                        "partial state was written as if it were complete."
                )
            default:
                break
            }
        }
        return lines
    }

    /// The opening of a `cardReclaimed` line: stopped by the Operator, stopped by the engine, or a plain reclaim.
    private static func reclaimedLine(
        cardID: Int64, issueID: String, previousRunID: RunID, outcome: String?, journal: JournalStore
    ) throws -> String {
        let mandated = "the Card is reclaimable, and no partial state was written as if it were complete."
        if outcome == AttemptEnding.aborted.consumedHow {
            return "Card `\(issueID)` was stopped by the Operator. Its Lease, held by run " +
                "`\(previousRunID)`, was reclaimed: \(mandated)"
        }
        if let engineStop = try journal.engineStopCause(cardID: cardID, runID: previousRunID) {
            return "Card `\(issueID)` was stopped by the engine: \(engineStop). Its Lease, held by run " +
                "`\(previousRunID)`, was left to expire and reclaimed: \(mandated)"
        }
        return "Card `\(issueID)`'s Lease, held by run `\(previousRunID)`, was reclaimed: \(mandated)"
    }

    /// The Exception line for a failed mainline or tag fetch; nil for any other event.
    private static func fetchFailureLine(_ event: JournalEvent) -> String? {
        switch event {
        case .mainlineFetchFailed(let repository, let reason):
            "Fetching mainline for `\(repository)` failed: \(reason)."
        case .tagFetchFailed(let repository, let reason):
            "Fetching tags for `\(repository)` failed: \(reason). The release gate reads only the tags it "
                + "already has, so a release it could not fetch keeps the gate closed."
        default:
            nil
        }
    }

    /// The `**Exceptions:**` section: `boardWriteFailed`, `rateBudgetExhausted`, `mainlineFetchFailed`,
    /// `tagFetchFailed`, `pullRequestReadFailed` (once per repository; ``pullRequestReadFailureLines(events:)``), `absentNightDetected`, `notificationDeliveryFailed`, `worktreeNameCollision`, a
    /// `flushFiringRan` that closed the Night (the closing land did not), a `worktreeLost` that
    /// recovered nothing (OQ133; ``worktreeLossLines(night:journal:)``) and `overrideRefused` — the last
    /// once per Card and reason, however many Acts refused it (OQ126) — plus one line per recovery of failed
    /// Acts (``recoveredFailureLines(events:renderingRunID:timeZone:)``, its time in `timeZone`). Empty when
    /// none of these happened this Night.
    public static func exceptionLines(
        night: NightRecord, journal: JournalStore, renderingRunID: RunID? = nil,
        timeZone: TimeZone = .current
    ) throws -> [String] {
        var lines: [String] = []
        let events = try nightEvents(night: night, journal: journal)
        // `landedPinFailed` is excluded by name: Journal-only by ruling (feature-authoring/
        // select-the-next-feature, OQ164). The push counted and the landed commit is recorded, so a pin that
        // could not be written or deleted is no Exception and no Night Card line.
        for record in events where record.type != .landedPinFailed {
            switch record.event {
            case .boardWriteFailed(_, let operation, let issueID, let reason):
                let named = issueID.map { " on `\($0)`" } ?? ""
                lines.append("A board write permanently failed: \(operation)\(named) — \(reason).")
            case .rateBudgetExhausted(let degradation, let installation):
                if let installation {
                    lines.append(
                        "The board's request budget was exhausted installation-wide, on Linear workspace "
                            + "\"\(installation.name)\" (shared by every Project on that workspace's App "
                            + "Installation): \(degradation)."
                    )
                } else {
                    lines.append("The board's request budget was exhausted installation-wide: \(degradation).")
                }
            case .absentNightDetected(let nightStart):
                lines.append("Night `\(nightStart)` did not open: reported only, not spent against a Bound.")
            case .notificationDeliveryFailed(let notification, let reason):
                lines.append(
                    "Notification `\(notification)` delivery failed: \(reason). Fire-and-forget: never retried."
                )
            case .worktreeNameCollision(let repository, let requested, let reported):
                lines.append(
                    "A Worktree branch-name collision in `\(repository)` halted the build Act: Orca ADE made "
                        + "`\(reported)`, not `\(requested)`. Later Acts retry."
                )
            case .flushFiringRan(.closedNight, _):
                lines.append(
                    "The Night's closing land did not close it: a flush firing closed it at "
                        + "\(record.occurredAt.formatted(.iso8601))."
                )
            default:
                if let line = Self.fetchFailureLine(record.event) { lines.append(line) }
            }
        }
        return lines
            + pullRequestReadFailureLines(events: events)
            + (try repeatedAuthoringFaultLines(events: events, journal: journal))
            + recoveredFailureLines(events: events, renderingRunID: renderingRunID, timeZone: timeZone)
            + (try worktreeLossLines(night: night, journal: journal))
            + (try overrideRefusalLines(night: night, journal: journal))
    }

    /// One line per repository whose pull request read failed this Night (`pull_request_read_failed`; spec:
    /// morning-report/write-the-night-summary `#pull-request-read-notes`, OQ190 items 12 and 28), however many passes
    /// failed, in the order each repository first failed, with each distinct reason. Noted as a failed mainline
    /// fetch is: never a failure line and never in the verdict, because the content test still ran.
    static func pullRequestReadFailureLines(events: [JournalEventRecord]) -> [String] {
        var repositories: [String] = []
        var reasons: [String: [PullRequestReadFailure.Reason]] = [:]
        for record in events {
            guard case .pullRequestReadFailed(let repository, let reason) = record.event else { continue }
            if reasons[repository] == nil { repositories.append(repository) }
            if !(reasons[repository] ?? []).contains(reason) { reasons[repository, default: []].append(reason) }
        }
        return repositories.map { repository in
            let named = (reasons[repository] ?? []).map(\.words).joined(separator: "; ")
            return "Reading the pull request in `\(repository)` failed: \(named). "
                + "Not a failure: the merge test went on without it."
        }
    }

    private static func repeatedAuthoringFaultLines(
        events: [JournalEventRecord], journal: JournalStore
    ) throws -> [String] {
        var lines: [String] = []
        for record in events {
            let name: String
            switch record.event {
            case .featureBreakdownRejected(let feature, _), .featureAuthoringFailed(let feature, _, _):
                name = feature
            case .featureAuthoringHalted(let feature, let kind, _) where kind == "authoring-repeatedly-faulted":
                name = feature
            default: continue
            }
            guard let feature = FeatureName(rawValue: name) else { continue }
            let count = try journal.authoringFaultCount(feature: feature, throughEventID: record.id).count
            guard count > 0 else { continue }
            let issue = try AuthoringStopBoard.knownIssueID(feature, journal)
                .map { " (Feature Card `\($0.rawValue)`)" } ?? ""
            let line = "Feature `\(name)`\(issue) faulted on its last \(count) authoring runs."
            if !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

    /// One line per Card and reason a Card override was refused for this Night (OQ126).
    static func overrideRefusalLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for record in try nightEvents(night: night, journal: journal) {
            guard case .overrideRefused(_, let issueID, let reason) = record.event else { continue }
            let line = "`\(issueID)` was not dispatched and spent no Attempt: \(reason)."
            if !lines.contains(line) {
                lines.append(line)
            }
        }
        return lines
    }
}
