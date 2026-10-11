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

    /// One line per recovery: the consecutive failed runs that the same later ended run recovered share a
    /// line, worded `1 Act failed, recovered 00:15`. Failures nothing recovered get no line (the verdict and
    /// the flush-firing line report them).
    static func recoveredFailureLines(
        events: [JournalEventRecord], renderingRunID: RunID?, timeZone: TimeZone
    ) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var lines: [String] = []
        var failed = 0
        for run in nightRuns(events: events, renderingRunID: renderingRunID) {
            if run.failed {
                failed += 1
                continue
            }
            if failed > 0 {
                let parts = calendar.dateComponents([.hour, .minute], from: run.startedAt)
                let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
                lines.append("\(failed) Act\(failed == 1 ? "" : "s") failed, recovered \(time)")
            }
            failed = 0
        }
        return lines
    }
}
