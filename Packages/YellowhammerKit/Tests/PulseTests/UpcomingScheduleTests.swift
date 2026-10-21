import Config
import Domain
import Foundation
import Testing

@testable import Pulse

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

/// 2026-10-19 at `hour:minute` UTC.
private func at(_ hour: Int, _ minute: Int, day: Int = 19) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func upcoming(_ asOf: Date, staggerIndex: Int = 0) throws -> UpcomingSchedule {
    try #require(UpcomingSchedule(schedule: Schedule(), staggerIndex: staggerIndex, asOf: asOf, calendar: calendar))
}

@Test("Before night_start: the next Act is tonight's author, and the Night has not opened")
func beforeNightStart() throws {
    let result = try upcoming(at(19, 30))

    #expect(result.nextAct == ScheduledAct(act: .author, at: at(22, 0)))
    #expect(result.night.startsAt == at(22, 0))
    #expect(result.night.endsAt == at(6, 0, day: 20))
    #expect(!result.night.isOpen)
}

@Test("During the Night window: the next Act is the following periodic tick, and the window is open")
func duringNight() throws {
    let result = try upcoming(at(23, 40))

    #expect(result.nextAct == ScheduledAct(act: .land, at: at(23, 45)))
    #expect(result.night.startsAt == at(22, 0))
    #expect(result.night.isOpen)
}

@Test("After midnight, still inside the window that opened yesterday")
func afterMidnightInsideWindow() throws {
    let result = try upcoming(at(2, 5))

    #expect(result.nextAct == ScheduledAct(act: .land, at: at(2, 15)))
    #expect(result.night.startsAt == at(22, 0, day: 18))
    #expect(result.night.endsAt == at(6, 0))
    #expect(result.night.isOpen)
}

@Test("After night_end: the next firing is a flush land, and the next Night is tonight's")
func afterNightEnd() throws {
    let result = try upcoming(at(6, 30))

    #expect(result.nextAct == ScheduledAct(act: .land, at: at(7, 0)))
    #expect(result.night.startsAt == at(22, 0))
    #expect(!result.night.isOpen)
}

@Test("Late in the day the next Act is tomorrow's author when no flush firing remains")
func rollsOverToTomorrow() throws {
    let result = try upcoming(at(21, 59))
    #expect(result.nextAct == ScheduledAct(act: .author, at: at(22, 0)))

    let past = try upcoming(at(22, 0))
    #expect(past.nextAct == ScheduledAct(act: .land, at: at(22, 15)))
}

@Test("The stagger index shifts the window and the Acts")
func staggered() throws {
    let result = try upcoming(at(19, 30), staggerIndex: 2)

    #expect(result.nextAct == ScheduledAct(act: .author, at: at(22, 6)))
    #expect(result.night.startsAt == at(22, 6))
    #expect(result.night.endsAt == at(6, 6, day: 20))
}

@Test("After a periodic land tick and its build, the next Act is the author firing two minutes after the land tick")
func nextAuthorFiringFollowsTheLandTick() throws {
    // 22:15 land, 22:16 build, 22:17 author (stagger 0, defaults)
    let result = try upcoming(at(22, 16))

    #expect(result.nextAct == ScheduledAct(act: .author, at: at(22, 17)))
}
