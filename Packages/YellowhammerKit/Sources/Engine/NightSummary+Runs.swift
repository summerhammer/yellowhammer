import Domain
import Foundation
import Journal

// The Acts ("runs") of one Night, derived from its events alone (Transient Board Failure Ruling
// 2026-10-09, OQ155 (1)). The Night Summary's verdict leads with `halted`/`crashed` only when the
// Night's last Act failed unrecovered, and its `**Exceptions:**` section names the failures a later Act
// recovered — both read this list.

extension NightSummary {
    /// How one Act of the Night ended.
    enum RunOutcome: Equatable {
        /// `ActEnded`, or the Act rendering the summary (its own terminal event is not written yet).
        case ended
        /// `ActIncomplete`.
        case halted
        /// Neither terminal event, and not the Act rendering the summary.
        case crashed
    }

    /// One Act of the Night: a distinct run id with `ActStarted` this Night.
    struct NightRun: Equatable {
        let runID: RunID
        let startedAt: Date
        let outcome: RunOutcome

        var failed: Bool { outcome != .ended }
    }

    /// The Night's Acts in the order they started, flush-firing runs excluded: a flush firing does no Night
    /// work, so it neither fails nor recovers anything. `renderingRunID` is the Act computing the summary —
    /// inside `closeNightIfNeeded`, before its own terminal event — and counts as ended. Deliberately not
    /// "the latest unterminated run is live": a crashed closing land that a flush firing then closed would
    /// read as live and render `closed`.
    static func nightRuns(events: [JournalEventRecord], renderingRunID: RunID?) -> [NightRun] {
        let flushRuns = Set(events.filter { $0.type == .flushFiringRan }.compactMap(\.runID))
        var order: [RunID] = []
        var startedAt: [RunID: Date] = [:]
        var halted: Set<RunID> = []
        var ended: Set<RunID> = []
        for record in events {
            guard let runID = record.runID, !flushRuns.contains(runID) else { continue }
            switch record.type {
            case .actStarted:
                if startedAt[runID] == nil {
                    order.append(runID)
                    startedAt[runID] = record.occurredAt
                }
            case .actIncomplete:
                halted.insert(runID)
            case .actEnded:
                ended.insert(runID)
            default:
                break
            }
        }
        return order.compactMap { runID in
            guard let started = startedAt[runID] else { return nil }
            let outcome: RunOutcome
            if halted.contains(runID) {
                outcome = .halted
            } else if ended.contains(runID) || runID == renderingRunID {
                outcome = .ended
            } else {
                outcome = .crashed
            }
            return NightRun(runID: runID, startedAt: started, outcome: outcome)
        }
    }

    /// One line per recovery minute, in the order the recoveries happened: `1 Act failed (the Act could not
    /// complete), recovered 00:15`. A failed run is recovered by cause (`Journal.ActFailures`,
    /// morning-report/disclose-a-failure#recovered) — a later run of the same Act getting past what failed —
    /// at that run's checkpoint. A crashed run records no cause, so the next later ended run recovers it, at
    /// that run's start, and the line says it died without recording why (a notice never invents a cause).
    /// Failures nothing recovered get no line (the verdict and the flush-firing line report them). The
    /// parenthetical is the cause when every run on the line shares one.
    static func recoveredFailureLines(
        events: [JournalEventRecord], renderingRunID: RunID?, timeZone: TimeZone
    ) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let runs = nightRuns(events: events, renderingRunID: renderingRunID)
        let crashed = Set(runs.filter { $0.outcome == .crashed }.map(\.runID.rawValue))
        let failures = ActFailures(events: withoutFlushFirings(events), renderingRunID: renderingRunID)
        let recoveredRuns = recoveredActFailureRuns(failures, excluding: crashed)
        var recoveries = recoveredRuns + runs.enumerated().compactMap { index, run -> RecoveredRun? in
            guard run.outcome == .crashed,
                let next = runs[(index + 1)...].first(where: { $0.outcome == .ended }) else { return nil }
            return RecoveredRun(at: next.startedAt, cause: Self.crashedCause)
        }
        recoveries.sort { $0.at < $1.at }
        var order: [String] = []
        var groups: [String: [RecoveredRun]] = [:]
        for recovery in recoveries {
            let parts = calendar.dateComponents([.hour, .minute], from: recovery.at)
            let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            if groups[time] == nil { order.append(time) }
            groups[time, default: []].append(recovery)
        }
        return order.map { time in
            let group = groups[time] ?? []
            let causes = Set(group.map(\.cause))
            let cause = causes.count == 1 ? causes.first.flatMap { $0 }.map { " (\($0))" } ?? "" : ""
            return "\(group.count) Act\(group.count == 1 ? "" : "s") failed\(cause), recovered \(time)"
        }
    }

    /// The cause of a run that died: it recorded none (morning-report/disclose-a-failure, "A notice never
    /// invents a cause").
    private static let crashedCause = "the run died without recording why"

    /// One failed run that a later run recovered: when, and the one cause it failed with (nil when it
    /// recorded several).
    private struct RecoveredRun {
        let at: Date
        let cause: String?
    }

    /// Each run whose every Act failure was recovered, once, at its latest recovery.
    private static func recoveredActFailureRuns(
        _ failures: ActFailures, excluding crashed: Set<String>
    ) -> [RecoveredRun] {
        let byRun = Dictionary(grouping: failures.all.filter { !crashed.contains($0.runKey) }, by: \.runKey)
        let causes = Dictionary(grouping: failures.failures, by: \.runKey).mapValues { Set($0.map(\.cause)) }
        return byRun.compactMap { runKey, runFailures -> RecoveredRun? in
            let dates = runFailures.compactMap { failures.recoveredAt($0, ignoringLaterFailures: true) }
            guard dates.count == runFailures.count, let at = dates.max() else { return nil }
            let runCauses = causes[runKey] ?? []
            return RecoveredRun(at: at, cause: runCauses.count == 1 ? runCauses.first?.phrase : nil)
        }
    }
}
