import Domain
import Foundation
import Journal

// The Night Summary's `**Failures:**` section (spec: morning-report/write-the-night-summary#failure-line,
// morning-report/disclose-a-failure#four-parts, #next-actions, #one-notice-per-run, #log-path). Every
// unrecovered Act failure of the Night is one Failure Notice, with what failed, why, where to look, what
// Yellowhammer does next and what the Operator may do. Wording is the glossary's: Work Card, Feature Card,
// Board Connection, Routing Table, Act.

extension NightSummary {
    /// The `**Failures:**` section's bullets: one per Failure Notice no later run recovered, in Journal order,
    /// then — when the Night also had failures that are no Act failure — one pointer bullet to the sections
    /// that state them. Empty when the Night has neither, so a quiet Night renders no section.
    ///
    /// A notice is recovered by the same per-run reading the `**Exceptions:**` recovered lines use, so the
    /// Night Card never says a failure is both recovered and standing. The log path is rendered with `~`,
    /// never the machine's home directory: the block is hashed for Outbox idempotency.
    public static func failureLines(
        night: NightRecord, journal: JournalStore, renderingRunID: RunID? = nil,
        consecutiveAuthoringFaultsMax: Int = 3, timeZone: TimeZone = .current
    ) throws -> [String] {
        let events = try nightEvents(night: night, journal: journal)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var lines: [String] = []
        for notice in unrecoveredNotices(events: events, renderingRunID: renderingRunID) {
            guard let first = notice.first, let last = notice.last else { continue }
            let runs = Set(notice.map(\.runKey)).count
            let from = clock(first.record.occurredAt, calendar)
            let until = clock(last.record.occurredAt, calendar)
            let span = runs > 1 ? " · \(runs) times, \(from)–\(until)" : ""
            let guidance = guidance(
                for: first, projectID: journal.projectID, faultsMax: consecutiveAuthoringFaultsMax
            )
            lines.append(
                "**\(first.headline)**\(span) — cause: \(first.cause.phrase); \(oneLine(first.reason)). "
                    + "Details: \(guidance.details). Next: \(guidance.next). You may: \(guidance.mayDo)."
            )
        }
        if let pointer = alsoThisNightLine(events: events, renderingRunID: renderingRunID) {
            lines.append(pointer)
        }
        return lines
    }

    /// The short copy of the closed Exception Notification: the headline of the Night's first unrecovered
    /// Failure Notice, with ` (and N more)` when N more are unrecovered. Nil when there is none — failures
    /// that are no Act failure (``alsoThisNightLine``) make no line on their own. The notification adds no
    /// event; it carries what the Night Card's `**Failures:**` section states
    /// (morning-report/notify-the-operator-of-exceptions).
    public static func notificationFailureLine(
        night: NightRecord, journal: JournalStore, renderingRunID: RunID? = nil
    ) throws -> String? {
        let events = try nightEvents(night: night, journal: journal)
        let notices = unrecoveredNotices(events: events, renderingRunID: renderingRunID)
        guard let headline = notices.first?.first?.headline else { return nil }
        return notices.count > 1 ? "\(headline) (and \(notices.count - 1) more)" : headline
    }

    /// The Night's Failure Notices (each a fold of failures) that no later run recovered, in Journal order.
    private static func unrecoveredNotices(
        events: [JournalEventRecord], renderingRunID: RunID?
    ) -> [[ActFailure]] {
        let failures = ActFailures(events: withoutFlushFirings(events), renderingRunID: renderingRunID)
        return failures.notices.filter { notice in
            notice.last.map { failures.recoveredAt($0, ignoringLaterFailures: true) == nil } ?? false
        }
    }

    /// The events without those of flush-firing runs: a flush firing neither fails nor recovers anything.
    static func withoutFlushFirings(_ events: [JournalEventRecord]) -> [JournalEventRecord] {
        let flushRuns = Set(events.filter { $0.type == .flushFiringRan }.compactMap(\.runID))
        return events.filter { record in record.runID.map { !flushRuns.contains($0) } ?? true }
    }

    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// The reason on one line, without a closing full stop (the bullet adds its own).
    private static func oneLine(_ reason: String) -> String {
        var text = DescriptionBudgetOverrun.oneLineReason(reason)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private struct Guidance {
        let details: String
        let next: String
        let mayDo: String
    }

    /// Where to look, what Yellowhammer does next, and what the Operator may do, by cause
    /// (disclose-a-failure#next-actions).
    private static func guidance(for failure: ActFailure, projectID: ProjectID, faultsMax: Int) -> Guidance {
        let act = failure.record.act
        let actName = act?.rawValue ?? "Act"
        let afresh = "the next author Act authors it afresh; after \(faultsMax) faults in a row authoring halts "
            + "and the Feature Card waits on you"
        switch failure.cause {
        case .overDescriptionBudget:
            return Guidance(
                details: "see Authoring below", next: afresh,
                mayDo: "shorten or split the Feature's specification first, or raise this Board Connection's "
                    + "description budget (default 10,000, at most 90% of the board's limit) in Settings › "
                    + "Board connections"
            )
        case .invalidBreakdown, .authoringRoutesFailed:
            return Guidance(
                details: "see Authoring below", next: afresh, mayDo: "nothing; the next author Act authors afresh"
            )
        case .noAuthoringRoute:
            return Guidance(
                details: "see Authoring below", next: afresh, mayDo: "check the Routing Table's authoring entries"
            )
        case .authoringTransactionFailed:
            return Guidance(
                details: "see Authoring below", next: afresh,
                mayDo: "check the Board Connection in Settings › Board connections"
            )
        case .selectionFailed:
            return Guidance(
                details: "see Authoring below", next: "the next author Act selects afresh", mayDo: "nothing"
            )
        case .authoringInvariantBroken:
            return Guidance(
                details: "see Anomalies below",
                next: "its Work Card is Blocked `authoring defect` and waits on you",
                mayDo: "answer the Blocked Work Card in Linear"
            )
        case .boardScopeUnresolved:
            return Guidance(
                details: logPointer(act, actName, projectID),
                next: "every Act does no work until the board scope resolves",
                mayDo: "provision the missing item the reason names in Linear, or re-run setup"
            )
        case .laneFailed, .actIncomplete:
            return Guidance(
                details: logPointer(act, actName, projectID), next: "the next \(actName) Act tries again",
                mayDo: "nothing is required; the log is in the details"
            )
        }
    }

    private static func logPointer(_ act: Act?, _ actName: String, _ projectID: ProjectID) -> String {
        guard let act else { return "the Night's account in Yellowhammer" }
        return "the \(actName) Act's log, `\(act.logPath(projectID: projectID, homeDirectory: "~"))`"
    }

    /// One pointer bullet to the sections that state this Night's failures that are no Act failure, each only
    /// when it happened. A kind the named section does not render points to the Night's account instead.
    private static func alsoThisNightLine(events: [JournalEventRecord], renderingRunID: RunID?) -> String? {
        var boardWrites = 0
        var reclaims = 0
        var hardFailedAttempts = 0
        var failedLandSteps = 0
        for record in events {
            switch record.event {
            case .boardWriteFailed: boardWrites += 1
            case .leaseReclaimed, .cardLeaseReclaimed, .nightOpenedAndDied: reclaims += 1
            case .attemptEnded(_, _, _, _, let outcome, _) where outcome == AttemptOutcome.hardFailure.rawValue:
                hardFailedAttempts += 1
            case .landStep(_, _, .failed, _): failedLandSteps += 1
            default: break
            }
        }
        let crashedRuns = unrecoveredCrashedRuns(events: events, renderingRunID: renderingRunID)
        let account = "see the Night's account in Yellowhammer"
        let parts = [
            (boardWrites, "board write\(boardWrites == 1 ? "" : "s") failed permanently", "see Exceptions below"),
            (reclaims, "crash\(reclaims == 1 ? "" : "es") or reclaimed Lease\(reclaims == 1 ? "" : "s")",
                "see Crashes and reclaims below"),
            (crashedRuns, "crashed run\(crashedRuns == 1 ? "" : "s")", account),
            (hardFailedAttempts, "hard-failed Attempt\(hardFailedAttempts == 1 ? "" : "s")", "see Cards below"),
            (failedLandSteps, "failed landing step\(failedLandSteps == 1 ? "" : "s")", account)
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1) — \($0.2)" }
        return parts.isEmpty ? nil : "Also this Night: \(parts.joined(separator: ", "))."
    }

    /// Crashed runs no later ended run recovered (the rule of ``recoveredFailureLines``).
    private static func unrecoveredCrashedRuns(events: [JournalEventRecord], renderingRunID: RunID?) -> Int {
        let runs = nightRuns(events: events, renderingRunID: renderingRunID)
        return runs.enumerated().count { index, run in
            run.outcome == .crashed && !runs[(index + 1)...].contains { $0.outcome == .ended }
        }
    }
}
