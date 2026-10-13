import Foundation
import Testing

@testable import Pulse

// The scale the Night is laid on: where a time falls along an axis of any length, and where the axis is
// labelled.

private typealias Fixture = NightTimelineFixture

private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    Fixture.clock(hour, minute, second)
}

extension NightTimelineTests {
    // MARK: The Night's scale

    @Test("A closed Night's scale runs from its opening to its close")
    func closedNightScale() {
        let scale = timeline.scale

        #expect(scale.start == at(14, 0))
        #expect(scale.end == at(15, 20))
        #expect(scale.span == 80 * 60)
    }

    @Test("An open Night's scale ends a quarter hour past the latest last entry of any run")
    func openNightScale() {
        // r2, the build Act's 14:10 run, ends at 14:55 and is not the last run to start.
        let open = Fixture.night(account.runs, completed: nil)

        #expect(NightTimeScale(account: open).end == at(15, 10))
        #expect(NightTimeline(account: open).scale.end == at(15, 10))
    }

    @Test("An open Night with no run ends a quarter hour after it opened")
    func openNightWithoutRuns() {
        let scale = NightTimeScale(account: Fixture.night([], opened: at(14, 0), completed: nil))

        #expect(scale.end == at(14, 15))
    }

    // MARK: Positions

    @Test("A time maps to an offset along an axis and back, and an offset outside the axis is kept inside")
    func positionAndDateRoundTrip() {
        let scale = NightTimeScale(start: at(14, 0), end: at(15, 0))

        #expect(scale.position(at(14, 0), length: 600) == 0)
        #expect(scale.position(at(14, 30), length: 600) == 300)
        #expect(scale.position(at(15, 0), length: 600) == 600)
        #expect(scale.date(at: 300, length: 600) == at(14, 30))
        #expect(scale.date(at: scale.position(at(14, 45), length: 480), length: 480) == at(14, 45))
        #expect(scale.date(at: -50, length: 600) == at(14, 0))
        #expect(scale.date(at: 9_999, length: 600) == at(15, 0))
    }

    @Test("An axis with no length gives the start, and a scale with no span puts every time at zero")
    func degenerateScales() {
        let scale = NightTimeScale(start: at(14, 0), end: at(15, 0))
        #expect(scale.date(at: 100, length: 0) == at(14, 0))
        #expect(scale.date(at: 100, length: -5) == at(14, 0))

        let empty = NightTimeScale(start: at(14, 0), end: at(14, 0))
        #expect(empty.span == 0)
        #expect(empty.position(at(14, 30), length: 600) == 0)
    }

    @Test("A run overlaps the scale when any part of it, start to last entry, falls inside")
    func overlaps() throws {
        let scale = NightTimeScale(start: at(14, 20), end: at(14, 40))
        let runs = Dictionary(uniqueKeysWithValues: account.runs.map { ($0.id, $0) })

        #expect(scale.overlaps(try #require(runs["r2"])))  // 14:10 to 14:55 spans it
        #expect(scale.overlaps(try #require(runs["r4"])))  // 14:30 is inside it
        #expect(!scale.overlaps(try #require(runs["r1"])))  // ended at 14:05
        #expect(!scale.overlaps(try #require(runs["r3"])))  // 14:15 only
    }

    @Test("A scale is worded as its start and end")
    func words() {
        let scale = NightTimeScale(start: at(14, 0), end: at(15, 20))

        #expect(scale.words == "\(Fixture.words(at(14, 0))) \u{2013} \(Fixture.words(at(15, 20)))")
    }

    // MARK: Ticks

    @Test("A scale of 40 minutes or less is labelled every five minutes, none at the start or the end")
    func fiveMinuteTicks() {
        let scale = NightTimeScale(start: at(14, 0), end: at(14, 30))
        #expect(scale.ticks == [at(14, 5), at(14, 10), at(14, 15), at(14, 20), at(14, 25)])

        let forty = NightTimeScale(start: at(14, 0), end: at(14, 40))
        #expect(forty.ticks.count == 7)
        #expect(forty.ticks.last == at(14, 35))
    }

    @Test("Ticks are counted from the hour that holds the start, and none is at or before the start")
    func ticksStartAfterTheStart() {
        let scale = NightTimeScale(start: at(14, 7), end: at(14, 40))

        #expect(scale.ticks == [at(14, 10), at(14, 15), at(14, 20), at(14, 25), at(14, 30), at(14, 35)])
        #expect(scale.ticks.allSatisfy { $0 > scale.start && $0 < scale.end })
    }

    @Test("A scale of more than 40 minutes and up to two hours is labelled every quarter hour")
    func quarterHourTicks() {
        let short = NightTimeScale(start: at(14, 0), end: at(14, 41))
        #expect(short.ticks == [at(14, 15), at(14, 30)])

        let twoHours = NightTimeScale(start: at(14, 0), end: at(16, 0))
        #expect(twoHours.ticks == [
            at(14, 15), at(14, 30), at(14, 45), at(15, 0), at(15, 15), at(15, 30), at(15, 45)
        ])
    }

    @Test("A scale of more than two hours is labelled every hour")
    func hourlyTicks() {
        let scale = NightTimeScale(start: at(14, 0), end: at(16, 1))
        #expect(scale.ticks == [at(15, 0), at(16, 0)])

        let night = NightTimeScale(start: at(13, 45), end: at(18, 30))
        #expect(night.ticks == [at(14, 0), at(15, 0), at(16, 0), at(17, 0), at(18, 0)])
    }

    @Test("The ruler's ticks are every quarter hour, whatever the span")
    func quarterHours() {
        let short = NightTimeScale(start: at(14, 0), end: at(14, 30))
        #expect(short.quarterHours == [at(14, 15)])

        let long = NightTimeScale(start: at(14, 0), end: at(18, 0))
        #expect(long.quarterHours.count == 15)
        #expect(long.quarterHours.first == at(14, 15))
        #expect(long.quarterHours.last == at(17, 45))
        #expect(long.quarterHours.allSatisfy { $0 > long.start && $0 < long.end })
    }

    @Test("A scale with no span has no ticks")
    func noTicksWithoutASpan() {
        let empty = NightTimeScale(start: at(14, 0), end: at(14, 0))

        #expect(empty.ticks.isEmpty)
        #expect(empty.quarterHours.isEmpty)
    }
}
