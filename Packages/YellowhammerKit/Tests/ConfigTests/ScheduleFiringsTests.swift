import Config
import Domain
import Testing

@Test("firings: defaults, stagger index 0")
func firingsDefaultsIndex0() throws {
    let firings = try Schedule().firings(staggerIndex: 0)

    #expect(firings.author == [TimeOfDay(hour: 22, minute: 0)!])
    #expect(firings.build.count == 31)
    #expect(firings.build.first == TimeOfDay(hour: 22, minute: 15)!)
    #expect(firings.build.last == TimeOfDay(hour: 5, minute: 45)!)
    #expect(firings.land.count == 32)
    #expect(firings.land.last == TimeOfDay(hour: 6, minute: 0)!)
}

@Test("firings: defaults, stagger index 2 (offset 6m)")
func firingsDefaultsIndex2() throws {
    let firings = try Schedule().firings(staggerIndex: 2)

    #expect(firings.author == [TimeOfDay(hour: 22, minute: 6)!])
    #expect(firings.build.first == TimeOfDay(hour: 22, minute: 21)!)
    #expect(firings.build.last == TimeOfDay(hour: 5, minute: 51)!)
    #expect(firings.land.last == TimeOfDay(hour: 6, minute: 6)!)
}

@Test("firings: same-day window 01:00-05:00 every 20")
func firingsSameDayWindow() throws {
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 1, minute: 0)!, nightEnd: TimeOfDay(hour: 5, minute: 0)!,
        buildEveryMinutes: 20
    )
    let firings = try schedule.firings(staggerIndex: 0)

    #expect(firings.author == [TimeOfDay(hour: 1, minute: 0)!])
    #expect(firings.build.count == 11)
    #expect(firings.build.first == TimeOfDay(hour: 1, minute: 20)!)
    #expect(firings.build.last == TimeOfDay(hour: 4, minute: 40)!)
    #expect(firings.land.last == TimeOfDay(hour: 5, minute: 0)!)
}

@Test("firings: interval does not divide the window")
func firingsNonDividingInterval() throws {
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 22, minute: 0)!, nightEnd: TimeOfDay(hour: 6, minute: 0)!,
        buildEveryMinutes: 25
    )
    let firings = try schedule.firings(staggerIndex: 0)

    #expect(firings.build.last == TimeOfDay(hour: 5, minute: 55)!)
    #expect(firings.land.last == TimeOfDay(hour: 6, minute: 0)!)
    #expect(!firings.build.contains(TimeOfDay(hour: 6, minute: 0)!))
}

@Test("firings: refuses when the stagger offset consumes the whole window")
func firingsRefusesOffsetBeyondWindow() throws {
    // Window is 01:00-01:05 (5m). staggerIndex 2 -> offset 6m >= 5m.
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 1, minute: 0)!, nightEnd: TimeOfDay(hour: 1, minute: 5)!,
        buildEveryMinutes: 15
    )
    #expect(throws: Schedule.FiringGridError.self) {
        try schedule.firings(staggerIndex: 2)
    }
}

@Test("firings: refuses a 24-hour window")
func firingsRefuses24HourWindow() throws {
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 22, minute: 0)!, nightEnd: TimeOfDay(hour: 22, minute: 0)!
    )
    #expect(throws: Schedule.FiringGridError.self) {
        try schedule.firings(staggerIndex: 0)
    }
}
