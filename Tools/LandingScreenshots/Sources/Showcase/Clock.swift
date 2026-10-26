import Domain
import Foundation

@testable import Journal

/// Calendar arithmetic for one showcase: `night(h, m)` is `h:m` local on the Night's date, and an hour past 23
/// is the following day, so `night(27, 12)` is 03:12 the morning after.
struct ShowcaseClock {
    let now: Date
    let nightDay: Date
    let calendar: Calendar

    init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        nightDay = calendar.startOfDay(for: yesterday)
    }

    /// Wall-clock time, never elapsed time: the day is counted in calendar days and the time of day is set on
    /// that day, so a night with a clock change still reads 22:00.
    func night(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let day = calendar.date(byAdding: .day, value: hour / 24, to: nightDay) ?? nightDay
        return calendar.date(bySettingHour: hour % 24, minute: minute, second: second, of: day) ?? day
    }

    func ago(_ minutes: Int) -> Date {
        now.addingTimeInterval(-60 * TimeInterval(minutes))
    }

    func nightStart() throws -> NightStart {
        let parts = calendar.dateComponents([.year, .month, .day], from: nightDay)
        let text = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return try required(NightStart(rawValue: text))
    }
}

/// One Act run writing to the Journal: every write first heartbeats the Act Lease at the write's own time, so a
/// backdated stamp always falls inside a live lease.
struct ShowcaseRun {
    let journal: JournalStore
    let act: Act
    let runID: RunID
    let nightID: Int64

    /// Claims the lease for a fresh run and records `actStarted` at `time`.
    static func begin(_ journal: JournalStore, act: Act, nightID: Int64, at time: Date) throws -> ShowcaseRun {
        let run = ShowcaseRun(journal: journal, act: act, runID: RunID(), nightID: nightID)
        try run.record(.actStarted, at: time)
        return run
    }

    func beat(_ time: Date) throws {
        _ = try journal.claimActLease(act: act, runID: runID, mode: .real, now: time)
    }

    @discardableResult
    func record(_ event: JournalEvent, at time: Date) throws -> Int64 {
        try beat(time)
        return try journal.append(event, act: act, runID: runID, nightID: nightID, now: time)
    }

    /// Records `actEnded` and frees the Project.
    func finish(at time: Date) throws {
        try record(.actEnded, at: time)
        _ = try journal.releaseActLease(runID: runID)
    }
}

/// Writes collected out of order, played back in time order, so each Act run's events are appended
/// chronologically although the Repo Lanes run side by side.
struct ShowcaseScript {
    private struct Step {
        let time: Date
        let order: Int
        let action: (ShowcaseRun) throws -> Void
    }

    private var steps: [Step] = []

    mutating func at(_ time: Date, _ action: @escaping (ShowcaseRun) throws -> Void) {
        steps.append(Step(time: time, order: steps.count, action: action))
    }

    func play(on run: ShowcaseRun) throws {
        for step in steps.sorted(by: { ($0.time, $0.order) < ($1.time, $1.order) }) {
            try step.action(run)
        }
    }
}
