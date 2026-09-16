import Config
import Domain
import Foundation
import Testing

@Test("nightWindow: Default schedule 22:00–06:00")
func nightWindowDefaultSchedule() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Kyiv"))

    let schedule = Schedule()

    // 2026-09-15 23:00 → nightStart "2026-09-15", end 2026-09-16 06:00, not at end
    var components = DateComponents(year: 2026, month: 9, day: 15, hour: 23, minute: 0)
    let at2300 = try #require(calendar.date(from: components))
    let window = schedule.nightWindow(at: at2300, calendar: calendar)
    #expect(window.nightStart == NightStart(rawValue: "2026-09-15")!)
    #expect(!schedule.isAtOrPastNightEnd(at2300, calendar: calendar))

    // 2026-09-16 03:00 → "2026-09-15"
    components = DateComponents(year: 2026, month: 9, day: 16, hour: 3, minute: 0)
    let at0300 = try #require(calendar.date(from: components))
    let window2 = schedule.nightWindow(at: at0300, calendar: calendar)
    #expect(window2.nightStart == NightStart(rawValue: "2026-09-15")!)
    #expect(!schedule.isAtOrPastNightEnd(at0300, calendar: calendar))

    // 2026-09-16 06:00 exactly → "2026-09-15" and isAtOrPastNightEnd == true
    components = DateComponents(year: 2026, month: 9, day: 16, hour: 6, minute: 0)
    let at0600 = try #require(calendar.date(from: components))
    let window3 = schedule.nightWindow(at: at0600, calendar: calendar)
    #expect(window3.nightStart == NightStart(rawValue: "2026-09-15")!)
    #expect(schedule.isAtOrPastNightEnd(at0600, calendar: calendar))

    // 2026-09-16 14:00 → "2026-09-15" and at/past end
    components = DateComponents(year: 2026, month: 9, day: 16, hour: 14, minute: 0)
    let at1400 = try #require(calendar.date(from: components))
    let window4 = schedule.nightWindow(at: at1400, calendar: calendar)
    #expect(window4.nightStart == NightStart(rawValue: "2026-09-15")!)
    #expect(schedule.isAtOrPastNightEnd(at1400, calendar: calendar))

    // 2026-09-15 22:00 exactly → "2026-09-15"
    components = DateComponents(year: 2026, month: 9, day: 15, hour: 22, minute: 0)
    let at2200 = try #require(calendar.date(from: components))
    let window5 = schedule.nightWindow(at: at2200, calendar: calendar)
    #expect(window5.nightStart == NightStart(rawValue: "2026-09-15")!)
}

@Test("nightWindow: Daytime schedule 09:00–17:00")
func nightWindowDaytimeSchedule() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Kyiv"))

    let schedule = Schedule(nightStart: TimeOfDay(hour: 9, minute: 0)!, nightEnd: TimeOfDay(hour: 17, minute: 0)!)

    // 10:00 → today's date, end 17:00 same day
    var components = DateComponents(year: 2026, month: 9, day: 15, hour: 10, minute: 0)
    let at1000 = try #require(calendar.date(from: components))
    let window = schedule.nightWindow(at: at1000, calendar: calendar)
    #expect(window.nightStart == NightStart(rawValue: "2026-09-15")!)
    #expect(!schedule.isAtOrPastNightEnd(at1000, calendar: calendar))

    // 08:00 → yesterday
    components = DateComponents(year: 2026, month: 9, day: 15, hour: 8, minute: 0)
    let at0800 = try #require(calendar.date(from: components))
    let window2 = schedule.nightWindow(at: at0800, calendar: calendar)
    #expect(window2.nightStart == NightStart(rawValue: "2026-09-14")!)
}

@Test("nightWindow: UTC calendar respected")
func nightWindowUTCCalendar() throws {
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = TimeZone(abbreviation: "UTC")!

    let schedule = Schedule()

    // Same instant, different calendar interpretation
    var components = DateComponents(year: 2026, month: 9, day: 15, hour: 21, minute: 0) // 21:00 UTC
    let date = try #require(utcCalendar.date(from: components))
    let window = schedule.nightWindow(at: date, calendar: utcCalendar)

    // With UTC, 21:00 should be in the previous night (22:00 start was yesterday)
    #expect(window.nightStart == NightStart(rawValue: "2026-09-14")!)
}

@Test("nightWindow: start and end instants are correct")
func nightWindowInstants() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Kyiv"))

    let schedule = Schedule()

    var components = DateComponents(year: 2026, month: 9, day: 15, hour: 23, minute: 0)
    let at2300 = try #require(calendar.date(from: components))
    let window = schedule.nightWindow(at: at2300, calendar: calendar)

    // start should be 2026-09-15 22:00
    let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: window.start)
    #expect(startComponents.year == 2026)
    #expect(startComponents.month == 9)
    #expect(startComponents.day == 15)
    #expect(startComponents.hour == 22)
    #expect(startComponents.minute == 0)

    // end should be 2026-09-16 06:00
    let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: window.end)
    #expect(endComponents.year == 2026)
    #expect(endComponents.month == 9)
    #expect(endComponents.day == 16)
    #expect(endComponents.hour == 6)
    #expect(endComponents.minute == 0)
}
