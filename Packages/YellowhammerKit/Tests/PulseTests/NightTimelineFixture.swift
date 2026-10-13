import Domain
import Foundation

@testable import Pulse

/// Small `NightAccount` values with fixed times, for the timeline, moment and scale tests. Every time is on
/// 2026-10-11 in the Mac's time zone, and an expectation is worked out the same way the fixture is.
enum NightTimelineFixture {
    /// `hour:minute:second` on the Night of 2026-10-11.
    static func clock(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        let components = DateComponents(year: 2026, month: 10, day: 11)
        let day = Calendar.current.date(from: components) ?? epoch
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: second, of: day) ?? epoch
    }

    /// `14:05`, as a view words a time.
    static func words(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    static func entry(_ id: Int64, _ time: Date, problem: Bool = false) -> NightAccount.Entry {
        NightAccount.Entry(id: id, occurredAt: time, headline: "Entry \(id)", isProblem: problem)
    }

    static func run(
        _ id: String,
        act: String?,
        at start: Date,
        _ outcome: NightAccount.RunOutcome = .ended,
        entries: [NightAccount.Entry]
    ) -> NightAccount.ActRun {
        NightAccount.ActRun(id: id, act: act, startedAt: start, outcome: outcome, entries: entries)
    }

    /// A Night from `opened` to `completed`; open while `completed` is nil. Runs must be in start order.
    static func night(
        _ runs: [NightAccount.ActRun], opened: Date = clock(14, 0), completed: Date? = clock(15, 20)
    ) -> NightAccount {
        NightAccount(
            id: 1,
            nightStart: "2026-10-11",
            mode: .real,
            state: completed == nil ? .running : .done,
            openedAt: opened,
            completedAt: completed,
            closeReason: nil,
            nightCard: nil,
            runs: runs
        )
    }

    /// A closed Night, 14:00 to 15:20, with four runs in start order and two problems:
    ///
    /// - `r1` author, 14:00 to 14:05, ended.
    /// - `r2` build, 14:10 to 14:55, ended; a problem at 14:20 and another at 14:50.
    /// - `r3` land, 14:15 only, idle.
    /// - `r4` build, 14:30 only, stood down — it starts and ends inside `r2`.
    ///
    /// Entry ids are in account order, so by time they read 1, 2, 3, 7, 4, 8, 5, 6.
    static let standard: NightAccount = night([
        run("r1", act: "author", at: clock(14, 0), entries: [entry(1, clock(14, 0)), entry(2, clock(14, 5))]),
        run(
            "r2", act: "build", at: clock(14, 10),
            entries: [
                entry(3, clock(14, 10)), entry(4, clock(14, 20), problem: true),
                entry(5, clock(14, 50), problem: true), entry(6, clock(14, 55))
            ]
        ),
        run("r3", act: "land", at: clock(14, 15), .idle(reason: "nothing to land"), entries: [entry(7, clock(14, 15))]),
        run("r4", act: "build", at: clock(14, 30), .stoodDown, entries: [entry(8, clock(14, 30))])
    ])
}
