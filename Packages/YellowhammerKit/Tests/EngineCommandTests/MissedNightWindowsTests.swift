import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Suite("MissedNightDiagnosis: window selection")
struct MissedNightWindowsTests {
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

    private static func nightStart(_ text: String) -> NightStart {
        NightStart(rawValue: text)!
    }

    @Test("endedWindows skips a Night that has not ended yet")
    func endedWindowsSkipsUnended() {
        // now is inside 2026-09-23's Night (22:00 -> 06:00 next day), before it ends.
        let now = Self.date("2026-09-24 03:00:00 +0000")
        let windows = MissedNightDiagnosis.endedWindows(
            schedule: Self.schedule, now: now, calendar: Self.calendar, count: 2
        )
        #expect(windows.map(\.nightStart) == [Self.nightStart("2026-09-22"), Self.nightStart("2026-09-21")])
    }

    @Test("endedWindows includes the current Night once it has ended")
    func endedWindowsIncludesEndedCurrent() {
        let now = Self.date("2026-09-24 10:00:00 +0000")
        let windows = MissedNightDiagnosis.endedWindows(
            schedule: Self.schedule, now: now, calendar: Self.calendar, count: 3
        )
        #expect(windows.map(\.nightStart) == [
            Self.nightStart("2026-09-23"), Self.nightStart("2026-09-22"), Self.nightStart("2026-09-21")
        ])
    }

    @Test("missedWindows with no Journal examines only the latest ended window, and it is missed")
    func missedWindowsNoJournal() {
        let now = Self.date("2026-09-24 10:00:00 +0000")
        let missed = MissedNightDiagnosis.missedWindows(
            schedule: Self.schedule, recordedNights: nil, now: now, calendar: Self.calendar, examinedNights: 5
        )
        #expect(missed.map(\.nightStart) == [Self.nightStart("2026-09-23")])
    }

    @Test("missedWindows with a Journal that has never recorded a Night behaves like no Journal")
    func missedWindowsEmptyRecordedNights() {
        let now = Self.date("2026-09-24 10:00:00 +0000")
        let missed = MissedNightDiagnosis.missedWindows(
            schedule: Self.schedule, recordedNights: [], now: now, calendar: Self.calendar, examinedNights: 5
        )
        #expect(missed.map(\.nightStart) == [Self.nightStart("2026-09-23")])
    }

    @Test("missedWindows never charges a Project with Nights before its first recorded one")
    func missedWindowsNoNightsBeforeFirstRecorded() {
        let now = Self.date("2026-09-24 10:00:00 +0000")
        let missed = MissedNightDiagnosis.missedWindows(
            schedule: Self.schedule, recordedNights: [Self.nightStart("2026-09-22")], now: now,
            calendar: Self.calendar, examinedNights: 5
        )
        // Ended windows are 09-23, 09-22, 09-21, 09-20, 09-19; only 09-23 is later than the earliest
        // recorded Night (09-22), so only it can be missed.
        #expect(missed.map(\.nightStart) == [Self.nightStart("2026-09-23")])
    }

    @Test("missedWindows reports none when every candidate has a recorded Night")
    func missedWindowsNoneWhenAllRecorded() {
        let now = Self.date("2026-09-24 10:00:00 +0000")
        let recordedNights = [
            Self.nightStart("2026-09-21"), Self.nightStart("2026-09-22"), Self.nightStart("2026-09-23")
        ]
        let missed = MissedNightDiagnosis.missedWindows(
            schedule: Self.schedule, recordedNights: recordedNights,
            now: now, calendar: Self.calendar, examinedNights: 3
        )
        #expect(missed.isEmpty)
    }

    @Test("firingInstants places a time-of-day before night_start on the next calendar day")
    func firingInstantsWrapsToNextDay() {
        let window = Self.schedule.nightWindow(at: Self.date("2026-09-24 10:00:00 +0000"), calendar: Self.calendar)
        let instants = MissedNightDiagnosis.firingInstants(
            window: window,
            firings: [TimeOfDay(hour: 23, minute: 0)!, TimeOfDay(hour: 2, minute: 0)!],
            calendar: Self.calendar
        )
        #expect(instants == [
            Self.date("2026-09-23 23:00:00 +0000"),
            Self.date("2026-09-24 02:00:00 +0000")
        ])
    }
}
