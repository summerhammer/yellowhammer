import Config
import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

@Suite("MissedNightDiagnosis: cause precedence")
struct MissedNightDiagnosisTests {
    /// UTC, so DST never perturbs a fixed clock-time schedule.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// `night_start` 22:00, `night_end` 06:00 — the spec's default (G-7).
    private static let schedule = Schedule()

    private static func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text)!
    }

    private static func window(_ nightStartText: String) -> NightWindow {
        Self.schedule.nightWindow(at: Self.date("\(nightStartText) 23:00:00 +0000"), calendar: Self.calendar)
    }

    @Test("diagnose finds a pre-initialization crash from a pre-Night ActIncomplete event")
    func diagnosePreInitCrashFromJournalEvent() {
        let window = Self.window("2026-09-22")
        let event = JournalEventRecord(
            id: 1, event: .actIncomplete(reason: "could not read config.toml"), act: .author, runID: nil,
            nightID: nil, occurredAt: Self.date("2026-09-22 22:05:00 +0000")
        )
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [(.author, .loaded(runs: 1, lastExitCode: 1))],
            preOpenEvidence: .init(journalFailures: [event], logModifications: []), sleepHistory: nil
        )
        guard case .preInitializationCrash(let evidence) = cause else {
            Issue.record("expected preInitializationCrash, got \(cause)")
            return
        }
        #expect(evidence.count == 1)
        #expect(evidence[0].contains("author"))
        #expect(evidence[0].contains("could not read config.toml"))
    }

    @Test("diagnose ignores an ActIncomplete event that already belongs to a Night")
    func diagnoseIgnoresActIncompleteWithNight() {
        let window = Self.window("2026-09-22")
        let event = JournalEventRecord(
            id: 1, event: .actIncomplete(reason: "boom"), act: .author, runID: nil,
            nightID: 42, occurredAt: Self.date("2026-09-22 22:05:00 +0000")
        )
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [(.author, .notInstalled)],
            preOpenEvidence: .init(journalFailures: [event], logModifications: []), sleepHistory: nil
        )
        // Falls through to noRunnableJob since the event does not count as evidence.
        guard case .noRunnableJob = cause else {
            Issue.record("expected noRunnableJob, got \(cause)")
            return
        }
    }

    @Test("diagnose finds a pre-initialization crash from a LaunchAgent log written inside the window")
    func diagnosePreInitCrashFromLogModification() {
        let window = Self.window("2026-09-22")
        let url = URL(fileURLWithPath: "/Users/max/Library/Logs/Yellowhammer/alpha.author.log")
        let modification = MissedNightDiagnosis.LogModification(
            act: .author, url: url, modifiedAt: Self.date("2026-09-22 22:10:00 +0000"),
            lastLine: "  fatal: could not resolve HEAD  "
        )
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [(.author, .loaded(runs: 1, lastExitCode: nil))],
            preOpenEvidence: .init(journalFailures: [], logModifications: [modification]), sleepHistory: nil
        )
        guard case .preInitializationCrash(let evidence) = cause else {
            Issue.record("expected preInitializationCrash, got \(cause)")
            return
        }
        #expect(evidence.count == 1)
        #expect(evidence[0].contains("alpha.author.log"))
        #expect(evidence[0].contains("fatal: could not resolve HEAD"))
    }

    @Test("diagnose caps evidence text from a runaway log line to ~200 characters")
    func diagnoseTruncatesLongEvidence() {
        let window = Self.window("2026-09-22")
        let url = URL(fileURLWithPath: "/Users/max/Library/Logs/Yellowhammer/alpha.author.log")
        let modification = MissedNightDiagnosis.LogModification(
            act: .author, url: url, modifiedAt: Self.date("2026-09-22 22:10:00 +0000"),
            lastLine: String(repeating: "x", count: 400)
        )
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [(.author, .loaded(runs: 1, lastExitCode: nil))],
            preOpenEvidence: .init(journalFailures: [], logModifications: [modification]), sleepHistory: nil
        )
        guard case .preInitializationCrash(let evidence) = cause else {
            Issue.record("expected preInitializationCrash, got \(cause)")
            return
        }
        #expect(evidence[0].count < 400)
    }

    @Test("diagnose finds no runnable job when every LaunchAgent is not installed")
    func diagnoseNoRunnableJobAllNotInstalled() {
        let window = Self.window("2026-09-22")
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [
                (.author, .notInstalled), (.build, .notInstalled), (.land, .notInstalled)
            ],
            preOpenEvidence: .none, sleepHistory: nil
        )
        guard case .noRunnableJob(let jobs) = cause else {
            Issue.record("expected noRunnableJob, got \(cause)")
            return
        }
        #expect(jobs == [.author: .notInstalled, .build: .notInstalled, .land: .notInstalled])
    }

    @Test("diagnose finds no runnable job from a mix of disabled and not loaded")
    func diagnoseNoRunnableJobMixed() {
        let window = Self.window("2026-09-22")
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [
                (.author, .disabled), (.build, .notLoaded), (.land, .disabled)
            ],
            preOpenEvidence: .none, sleepHistory: nil
        )
        guard case .noRunnableJob(let jobs) = cause else {
            Issue.record("expected noRunnableJob, got \(cause)")
            return
        }
        #expect(jobs == [.author: .disabled, .build: .notLoaded, .land: .disabled])
    }

    @Test("diagnose finds asleep when a sleep interval covers every firing")
    func diagnoseAsleep() {
        let window = Self.window("2026-09-22")
        let interval = SleepInterval(
            start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000")
        )
        let history = SleepHistory(intervals: [interval], coverageStart: Self.date("2026-09-22 00:00:00 +0000"))
        let firings = [Self.date("2026-09-22 23:00:00 +0000"), Self.date("2026-09-23 02:00:00 +0000")]
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: firings, jobs: [(.author, .loaded(runs: 1, lastExitCode: nil))],
            preOpenEvidence: .none, sleepHistory: history
        )
        #expect(cause == .asleep([interval]))
    }

    @Test("diagnose does not find asleep when the sleep history does not reach back to window.start")
    func diagnoseNotAsleepWhenCoverageStartsLate() {
        let window = Self.window("2026-09-22")
        let interval = SleepInterval(
            start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000")
        )
        // The log starts after the window opens.
        let history = SleepHistory(intervals: [interval], coverageStart: Self.date("2026-09-22 22:30:00 +0000"))
        let firings = [Self.date("2026-09-22 23:00:00 +0000")]
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: firings, jobs: [(.author, .loaded(runs: 1, lastExitCode: nil))],
            preOpenEvidence: .none, sleepHistory: history
        )
        #expect(cause == .undiagnosed(sleepHistoryReachesBack: false))
    }

    @Test("diagnose is undiagnosed with sleepHistoryReachesBack true when jobs are loaded and awake")
    func diagnoseUndiagnosedReachesBack() {
        let window = Self.window("2026-09-22")
        let history = SleepHistory(intervals: [], coverageStart: Self.date("2026-09-22 00:00:00 +0000"))
        let firings = [Self.date("2026-09-22 23:00:00 +0000")]
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: firings, jobs: [(.author, .loaded(runs: 1, lastExitCode: nil))],
            preOpenEvidence: .none, sleepHistory: history
        )
        #expect(cause == .undiagnosed(sleepHistoryReachesBack: true))
    }

    @Test("diagnose is undiagnosed with sleepHistoryReachesBack false when there is no sleep history")
    func diagnoseUndiagnosedNoSleepHistory() {
        let window = Self.window("2026-09-22")
        let firings = [Self.date("2026-09-22 23:00:00 +0000")]
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: firings, jobs: [(.author, .loaded(runs: 1, lastExitCode: nil))],
            preOpenEvidence: .none, sleepHistory: nil
        )
        #expect(cause == .undiagnosed(sleepHistoryReachesBack: false))
    }

    @Test("diagnose prefers preInitializationCrash over noRunnableJob when both apply")
    func diagnosePrecedencePreInitOverNoRunnableJob() {
        let window = Self.window("2026-09-22")
        let event = JournalEventRecord(
            id: 1, event: .actIncomplete(reason: "boom"), act: .author, runID: nil,
            nightID: nil, occurredAt: Self.date("2026-09-22 22:05:00 +0000")
        )
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: [], jobs: [(.author, .notInstalled)],
            preOpenEvidence: .init(journalFailures: [event], logModifications: []), sleepHistory: nil
        )
        guard case .preInitializationCrash = cause else {
            Issue.record("expected preInitializationCrash, got \(cause)")
            return
        }
    }

    @Test("diagnose prefers noRunnableJob over asleep when both apply")
    func diagnosePrecedenceNoRunnableJobOverAsleep() {
        let window = Self.window("2026-09-22")
        let interval = SleepInterval(
            start: Self.date("2026-09-22 21:40:00 +0000"), end: Self.date("2026-09-23 07:10:00 +0000")
        )
        let history = SleepHistory(intervals: [interval], coverageStart: Self.date("2026-09-22 00:00:00 +0000"))
        let firings = [Self.date("2026-09-22 23:00:00 +0000")]
        let cause = MissedNightDiagnosis.diagnose(
            window: window, firings: firings, jobs: [(.author, .notInstalled)],
            preOpenEvidence: .none, sleepHistory: history
        )
        guard case .noRunnableJob = cause else {
            Issue.record("expected noRunnableJob, got \(cause)")
            return
        }
    }
}
