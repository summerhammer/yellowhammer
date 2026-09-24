import Config
import Domain
import Foundation
import Journal

/// Which Nights `yh status` should have seen and did not, and why — pure arithmetic and comparisons
/// over plain inputs, so P14.6 can move it into a module the app may link without dragging in `Engine`.
enum MissedNightDiagnosis {
    /// The ended Night windows `yh status` examines for `--nights` back from `now`: the last
    /// `count` windows whose `window.end` is at or before `now`. Steps back a calendar day at a time
    /// from the window containing `now`, skipping it first when it has not ended yet. Descending
    /// (most recent first).
    static func endedWindows(schedule: Schedule, now: Date, calendar: Calendar, count: Int) -> [NightWindow] {
        guard count > 0 else { return [] }
        var window = schedule.nightWindow(at: now, calendar: calendar)
        if window.end > now {
            guard let probe = calendar.date(byAdding: .day, value: -1, to: window.start) else { return [] }
            window = schedule.nightWindow(at: probe, calendar: calendar)
        }
        var windows: [NightWindow] = []
        while windows.count < count {
            windows.append(window)
            guard let probe = calendar.date(byAdding: .day, value: -1, to: window.start) else { break }
            window = schedule.nightWindow(at: probe, calendar: calendar)
        }
        return windows
    }

    /// The ended windows among the last `examinedNights` that this Project should have a recorded
    /// Night for and does not.
    ///
    /// With at least one recorded Night, a missed window is a candidate — one whose `nightStart` is
    /// later than the earliest recorded Night's — with no recorded Night of that `nightStart`: a
    /// Project cannot be charged Nights from before it existed. With none recorded (`recordedNights`
    /// nil, meaning no Journal, or empty), only the single most recent ended window is examined, and
    /// it is missed.
    static func missedWindows(
        schedule: Schedule, recordedNights: [NightStart]?, now: Date, calendar: Calendar, examinedNights: Int
    ) -> [NightWindow] {
        let candidates = endedWindows(schedule: schedule, now: now, calendar: calendar, count: examinedNights)
        guard let recordedNights, let earliest = recordedNights.min() else {
            return Array(candidates.prefix(1))
        }
        let recorded = Set(recordedNights)
        return candidates.filter { $0.nightStart > earliest && !recorded.contains($0.nightStart) }
    }

    /// The one instant inside `[window.start, window.end]` each `TimeOfDay` in `firings` names: on the
    /// window's start day when the time of day is at or after `night_start`'s, otherwise the next day.
    static func firingInstants(window: NightWindow, firings: [TimeOfDay], calendar: Calendar) -> [Date] {
        firings.map { timeOfDay in
            let onStartDay = calendar.date(
                bySettingHour: timeOfDay.hour, minute: timeOfDay.minute, second: 0, of: window.start
            ) ?? window.start
            guard onStartDay < window.start else { return onStartDay }
            return calendar.date(byAdding: .day, value: 1, to: onStartDay) ?? onStartDay
        }
    }

    /// One log file's modification, as evidence for a pre-initialization crash: which Act's
    /// LaunchAgent log it is, its path, when it was last modified, and its last non-empty line.
    struct LogModification: Equatable, Sendable {
        let act: Act
        let url: URL
        let modifiedAt: Date
        let lastLine: String?
    }

    /// Everything a pre-initialization crash can be diagnosed from: the Journal's pre-Night
    /// `ActIncomplete` events and each Act's LaunchAgent log modification. Grouped into one type so
    /// ``diagnose`` stays under the file's function-parameter-count limit.
    struct PreOpenEvidence: Equatable, Sendable {
        let journalFailures: [JournalEventRecord]
        let logModifications: [LogModification]

        static let none = PreOpenEvidence(journalFailures: [], logModifications: [])
    }

    /// Diagnoses why a missed Night's Acts never ran, in precedence order (first match wins):
    /// 1. `preInitializationCrash` — `yh` fired during the window but never opened the Night, evidenced
    ///    by a pre-Night `ActIncomplete` event or a LaunchAgent log file touched inside the window.
    /// 2. `noRunnableJob` — none of `jobs` can fire right now.
    /// 3. `asleep` — a sleep history reaching back to `window.start` covers every firing instant.
    /// 4. `undiagnosed` — none of the above explains it.
    static func diagnose(
        window: NightWindow,
        firings: [Date],
        jobs: [(act: Act, state: LaunchAgentJobState)],
        preOpenEvidence: PreOpenEvidence,
        sleepHistory: SleepHistory?
    ) -> MissedNightCause {
        let evidence = preInitializationCrashEvidence(window: window, preOpenEvidence: preOpenEvidence)
        guard evidence.isEmpty else { return .preInitializationCrash(evidence: evidence) }

        guard jobs.contains(where: { $0.state.canFire }) else {
            return .noRunnableJob(Dictionary(uniqueKeysWithValues: jobs.map { ($0.act, $0.state) }))
        }

        if let sleepHistory, sleepHistory.coverageStart <= window.start, !firings.isEmpty,
            firings.allSatisfy({ sleepHistory.isAsleep(at: $0) }) {
            let covering = sleepHistory.intervals.filter { interval in
                firings.contains { interval.start <= $0 && $0 < interval.end }
            }
            return .asleep(covering)
        }

        let reachesBack = sleepHistory.map { $0.coverageStart <= window.start } ?? false
        return .undiagnosed(sleepHistoryReachesBack: reachesBack)
    }

    private static func preInitializationCrashEvidence(
        window: NightWindow, preOpenEvidence: PreOpenEvidence
    ) -> [String] {
        var evidence: [String] = []
        for record in preOpenEvidence.journalFailures {
            guard
                record.nightID == nil, record.type == .actIncomplete,
                record.occurredAt >= window.start, record.occurredAt < window.end,
                case .actIncomplete(let reason) = record.event, let act = record.act
            else { continue }
            evidence.append("\(act.rawValue) failed before the Night opened: \(reason)")
        }
        for modification in preOpenEvidence.logModifications {
            guard modification.modifiedAt >= window.start, modification.modifiedAt < window.end else { continue }
            let path = modification.url.path(percentEncoded: false)
            if let lastLine = modification.lastLine.map(truncated), !lastLine.isEmpty {
                evidence.append("\(modification.act.rawValue) log \(path) ran: \(lastLine)")
            } else {
                evidence.append("\(modification.act.rawValue) log \(path) was written to")
            }
        }
        return evidence
    }

    /// `line`, trimmed and capped to ~200 characters, so one runaway log line cannot blow up the
    /// evidence text.
    private static func truncated(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 200 else { return trimmed }
        return String(trimmed.prefix(200)) + "…"
    }
}
