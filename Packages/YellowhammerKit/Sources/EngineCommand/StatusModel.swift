import Config
import Domain
import Foundation

/// `launchd`'s view of one of a Project's LaunchAgents, right now — what `yh status` reports per Act,
/// distinct from ``DoctorFinding``'s install/load pass-or-warn (P13.4 needs the finer states to explain
/// a missed Night).
enum LaunchAgentJobState: Equatable, Sendable {
    /// No `<label>.plist` in `~/Library/LaunchAgents`.
    case notInstalled
    /// The plist is present, but `launchctl print-disabled` reports the label disabled.
    case disabled
    /// The plist is present and not disabled, but `launchctl print` fails (not currently loaded).
    case notLoaded
    /// Loaded. `lastExitCode` is nil for `(never exited)` or when `launchctl print` omits it.
    case loaded(runs: Int?, lastExitCode: Int?)

    /// Whether this job could fire the next time `launchd` reaches its `StartCalendarInterval` —
    /// only ``loaded`` can.
    var canFire: Bool {
        if case .loaded = self { true } else { false }
    }
}

/// One span the Mac was asleep, as `pmset -g log` records it.
struct SleepInterval: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// The Mac's sleep/wake history, parsed from `pmset -g log`.
struct SleepHistory: Equatable, Sendable {
    /// Ascending, non-overlapping.
    let intervals: [SleepInterval]
    /// The earliest timestamp the log covers — before this instant, the log says nothing either way.
    let coverageStart: Date

    /// Whether `instant` falls inside one of `intervals` (start inclusive, end exclusive).
    func isAsleep(at instant: Date) -> Bool {
        intervals.contains { $0.start <= instant && instant < $0.end }
    }
}

/// Why a Night's Acts never ran, in the precedence `MissedNightDiagnosis.diagnose` applies (first
/// match wins).
enum MissedNightCause: Equatable, Sendable {
    /// `yh` fired during the Night but never opened it. Each string is one piece of evidence: a
    /// Journal `ActIncomplete` recorded before any Night existed, or a LaunchAgent log file that was
    /// written to inside the window.
    case preInitializationCrash(evidence: [String])
    /// None of the Project's three LaunchAgents can fire now (current state, not historic).
    case noRunnableJob([Act: LaunchAgentJobState])
    /// The Mac was asleep at every firing instant of the Night. Carries the sleep intervals that
    /// covered those firings.
    case asleep([SleepInterval])
    /// Nothing explains it. `sleepHistoryReachesBack` is false when `pmset`'s log starts after the
    /// Night, so sleep could not be ruled in or out.
    case undiagnosed(sleepHistoryReachesBack: Bool)
}

/// One Night `yh status` expected to have run and found missing, with its diagnosed cause.
struct MissedNight: Equatable, Sendable {
    let window: NightWindow
    let cause: MissedNightCause
}
