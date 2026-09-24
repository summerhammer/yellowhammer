import Domain
import Foundation

/// One Night's span on the clock, as the Project's `[schedule]` draws it.
public struct NightWindow: Equatable, Sendable {
    /// The Night: the date of its `night_start` (G-7).
    public let nightStart: NightStart
    /// The instant of that `night_start`.
    public let start: Date
    /// The instant of the `night_end` that follows it: the next calendar day's when `night_end` is
    /// not later in the day than `night_start`, otherwise the same day's.
    public let end: Date
}

extension Schedule {
    /// The Night `now` belongs to: the one whose `night_start` is the most recent at or before `now`.
    /// Every instant belongs to some Night, so a forced Act in the afternoon belongs to the Night
    /// that started the previous evening, and a land Act after `night_end` can still close it.
    public func nightWindow(at now: Date, calendar: Calendar = .current) -> NightWindow {
        let todayAtStart = calendar.instant(of: nightStart, onDayOf: now)
        let startDay = todayAtStart > now
            ? calendar.date(byAdding: .day, value: -1, to: now) ?? now
            : now
        return window(startingOnDayOf: startDay, calendar: calendar)
    }

    /// The window of the Night whose `night_start` falls on `nightStart`'s date — rehearsal-only, so a
    /// suite can run several successive Nights (Night 1, Night 2, Night 3) in one session instead of one
    /// Night per wall-clock day. Only the Night's identity moves: leases, heartbeats and every timestamp
    /// stay on the wall clock.
    public func nightWindow(for identity: NightStart, calendar: Calendar = .current) -> NightWindow {
        var components = DateComponents()
        components.year = identity.year
        components.month = identity.month
        components.day = identity.day
        let day = calendar.date(from: components) ?? Date()
        return window(startingOnDayOf: day, calendar: calendar)
    }

    /// Whether `now` is at or past the `night_end` of the Night it belongs to.
    public func isAtOrPastNightEnd(_ now: Date, calendar: Calendar = .current) -> Bool {
        now >= nightWindow(at: now, calendar: calendar).end
    }

    /// The Night whose `night_start` falls on the same calendar day as `day` (any instant of that day).
    private func window(startingOnDayOf day: Date, calendar: Calendar) -> NightWindow {
        let start = calendar.instant(of: nightStart, onDayOf: day)
        let endsNextDay = nightEnd.minutesSinceMidnight <= nightStart.minutesSinceMidnight
        let sameDayEnd = calendar.instant(of: nightEnd, onDayOf: start)
        let end = endsNextDay
            ? calendar.date(byAdding: .day, value: 1, to: sameDayEnd) ?? sameDayEnd
            : sameDayEnd
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        guard
            let year = components.year, let month = components.month, let day = components.day,
            let identity = NightStart(year: year, month: month, day: day)
        else {
            // The calendar produced `start` itself, so its own components always name a date.
            preconditionFailure("\(calendar.identifier) produced a date NightStart cannot name: \(start)")
        }
        return NightWindow(nightStart: identity, start: start, end: end)
    }
}

extension TimeOfDay {
    var minutesSinceMidnight: Int { hour * 60 + minute }
}

extension Calendar {
    /// The instant of `time` on the calendar day that holds `day`.
    fileprivate func instant(of time: TimeOfDay, onDayOf day: Date) -> Date {
        date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
    }
}
