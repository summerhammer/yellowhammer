import Config
import Domain
import Testing

@Test("firings: defaults, stagger index 0")
func firingsDefaultsIndex0() throws {
    let firings = try Schedule().firings(staggerIndex: 0)

    #expect(firings.author == [TimeOfDay(hour: 22, minute: 0)!])
    #expect(firings.build.count == 31)
    #expect(firings.build.first == TimeOfDay(hour: 22, minute: 16)!)
    #expect(firings.build.last == TimeOfDay(hour: 5, minute: 46)!)
    #expect(firings.land.count == 32)
    #expect(firings.land.first == TimeOfDay(hour: 22, minute: 15)!)
    #expect(firings.land.last == TimeOfDay(hour: 6, minute: 0)!)
}

@Test("firings: worked example, 22:00-06:00 every 15, offset 3")
func firingsWorkedExample() throws {
    let firings = try Schedule().firings(staggerIndex: 1)

    func time(_ hour: Int, _ minute: Int) -> TimeOfDay { TimeOfDay(hour: hour, minute: minute)! }

    // build is exactly one minute after each periodic land tick: 22:19, 22:34, ... 05:49
    let expectedBuild = (1..<32).map { tick -> TimeOfDay in
        let absolute = (22 * 60 + 3 + tick * 15 + 1) % 1440
        return time(absolute / 60, absolute % 60)
    }
    #expect(firings.build == expectedBuild)
    #expect(firings.build.first == time(22, 19))
    #expect(firings.build[1] == time(22, 34))
    #expect(firings.build.last == time(5, 49))

    // land by membership: other Work Cards of this Feature append flush firings to land
    #expect(firings.land.contains(time(22, 18)))
    #expect(firings.land.contains(time(22, 33)))
    #expect(firings.land.contains(time(5, 48)))
    #expect(firings.land.contains(time(6, 3)))
    #expect(!firings.land.contains(time(22, 19)))

    #expect(firings.author == [time(22, 3)])
}

@Test("firings: defaults, stagger index 2 (offset 6m)")
func firingsDefaultsIndex2() throws {
    let firings = try Schedule().firings(staggerIndex: 2)

    #expect(firings.author == [TimeOfDay(hour: 22, minute: 6)!])
    #expect(firings.build.count == 31)
    #expect(firings.build.first == TimeOfDay(hour: 22, minute: 22)!)
    #expect(firings.build.last == TimeOfDay(hour: 5, minute: 52)!)
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
    #expect(firings.build.first == TimeOfDay(hour: 1, minute: 21)!)
    #expect(firings.build.last == TimeOfDay(hour: 4, minute: 41)!)
    #expect(firings.land.last == TimeOfDay(hour: 5, minute: 0)!)
}

@Test("firings: interval does not divide the window")
func firingsNonDividingInterval() throws {
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 22, minute: 0)!, nightEnd: TimeOfDay(hour: 6, minute: 0)!,
        buildEveryMinutes: 25
    )
    let firings = try schedule.firings(staggerIndex: 0)

    #expect(firings.build.count == 19)
    #expect(firings.build.last == TimeOfDay(hour: 5, minute: 56)!)
    #expect(firings.land.last == TimeOfDay(hour: 6, minute: 0)!)
    #expect(!firings.build.contains(TimeOfDay(hour: 6, minute: 0)!))
}

@Test("firings: build_every_minutes 1 leaves build on land's ticks")
func firingsEveryMinuteHasNoBuildOffset() throws {
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 1, minute: 0)!, nightEnd: TimeOfDay(hour: 1, minute: 10)!,
        buildEveryMinutes: 1
    )
    let firings = try schedule.firings(staggerIndex: 0)

    let ticks = (1...9).map { TimeOfDay(hour: 1, minute: $0)! }
    #expect(firings.build == ticks)
    #expect(firings.land == ticks + [TimeOfDay(hour: 1, minute: 10)!])
}

@Test("firings: build shift wraps at midnight")
func firingsBuildShiftWrapsAtMidnight() throws {
    // Window 23:00-01:00, every 59: land ticks 23:59 and 00:58; builds one minute later.
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 23, minute: 0)!, nightEnd: TimeOfDay(hour: 1, minute: 0)!,
        buildEveryMinutes: 59
    )
    let firings = try schedule.firings(staggerIndex: 0)

    #expect(firings.land.contains(TimeOfDay(hour: 23, minute: 59)!))
    #expect(firings.build == [TimeOfDay(hour: 0, minute: 0)!, TimeOfDay(hour: 0, minute: 59)!])
}

@Test("firings: the last build may share the Night-closing land's minute, and is kept")
func firingsLastBuildOnNightClosingLandMinute() throws {
    // Window 22:00-06:01 is 481m; with every 15, k = 32 gives a land tick at 06:00 (480m < 481m), so
    // its build falls on 06:01 — the Night-closing land's minute. The ruling keeps the same set of k.
    let schedule = Schedule(
        nightStart: TimeOfDay(hour: 22, minute: 0)!, nightEnd: TimeOfDay(hour: 6, minute: 1)!,
        buildEveryMinutes: 15
    )
    let firings = try schedule.firings(staggerIndex: 0)

    #expect(firings.build.count == 32)
    #expect(firings.build.last == TimeOfDay(hour: 6, minute: 1)!)
    #expect(firings.land.last == TimeOfDay(hour: 6, minute: 1)!)
    #expect(firings.land.contains(TimeOfDay(hour: 6, minute: 0)!))
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
