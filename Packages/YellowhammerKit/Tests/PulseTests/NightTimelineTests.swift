import Foundation
import Testing

@testable import Pulse

// The Night's account laid along time, and a playhead moved along it. The Night is drawn as a scrubbable
// timeline; these tests hold the plain values behind it. Acts and runs are in `NightTimelineTests+Acts.swift`,
// the time scale in `NightTimelineTests+Scale.swift`. Nothing here reads a Journal.

private typealias Fixture = NightTimelineFixture

private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    Fixture.clock(hour, minute, second)
}

@Suite
struct NightTimelineTests {
    let account = Fixture.standard
    var timeline: NightTimeline { NightTimeline(account: account) }

    // MARK: Opening

    @Test("The playhead opens on the Night's first problem")
    func openingIsTheFirstProblem() {
        #expect(timeline.opening == at(14, 20))
    }

    @Test("With no problem the playhead opens on the Night's opening, not on its first entry")
    func openingWithoutProblems() {
        let quiet = Fixture.night(
            [Fixture.run("r1", act: "build", at: at(14, 0), entries: [Fixture.entry(1, at(14, 0))])],
            opened: at(13, 45)
        )
        let timeline = NightTimeline(account: quiet)

        #expect(timeline.problemTimes.isEmpty)
        #expect(timeline.opening == at(13, 45))
    }

    // MARK: Items

    @Test("Items run in the order the entries occurred, each with the run that recorded it")
    func itemsInTimeOrder() {
        let items = timeline.items

        #expect(items.map(\.id) == [1, 2, 3, 7, 4, 8, 5, 6])
        #expect(items.first { $0.entry.id == 7 }?.run.id == "r3")
        #expect(items.first { $0.entry.id == 4 }?.run.id == "r2")
        #expect(items.count == account.runs.reduce(0) { $0 + $1.entries.count })
    }

    @Test("Entries that occurred at the same time keep the order of the account")
    func tiesKeepAccountOrder() {
        let tied = at(14, 10)
        let night = Fixture.night([
            Fixture.run("x", act: "author", at: at(14, 0), entries: [Fixture.entry(20, tied)]),
            Fixture.run("y", act: "build", at: at(14, 5), entries: [Fixture.entry(10, tied)]),
            Fixture.run("z", act: "land", at: at(14, 8), entries: [Fixture.entry(30, tied)])
        ])

        #expect(NightTimeline(account: night).items.map(\.id) == [20, 10, 30])
    }

    @Test("Problem times are sorted across runs, not in the order of the account")
    func problemTimesAreSorted() {
        let night = Fixture.night([
            Fixture.run("x", act: "author", at: at(14, 0), entries: [Fixture.entry(1, at(14, 40), problem: true)]),
            Fixture.run("y", act: "build", at: at(14, 10), entries: [Fixture.entry(2, at(14, 20), problem: true)])
        ])
        let timeline = NightTimeline(account: night)

        #expect(timeline.problemTimes == [at(14, 20), at(14, 40)])
        #expect(timeline.opening == at(14, 20))
        #expect(NightTimeline(account: account).problemTimes == [at(14, 20), at(14, 50)])
    }

    @Test("A moment carries the timeline and the time it was made at")
    func momentAt() {
        let moment = timeline.moment(at: at(14, 33))

        #expect(moment.time == at(14, 33))
        #expect(moment.timeline.account == account)
    }

    // MARK: Moving

    @Test("Moving the playhead stops at both ends of the Night")
    func movedStopsAtTheEnds() {
        let start = at(14, 0)
        let end = at(15, 20)
        let middle = timeline.moment(at: at(14, 30))

        #expect(middle.moved(by: 300) == at(14, 35))
        #expect(middle.moved(by: -300) == at(14, 25))
        #expect(middle.moved(by: 3 * 3_600) == end)
        #expect(middle.moved(by: -3 * 3_600) == start)
        #expect(timeline.moment(at: start).moved(by: -1) == start)
        #expect(timeline.moment(at: start).moved(by: 60) == at(14, 1))
        #expect(timeline.moment(at: end).moved(by: 1) == end)
        #expect(timeline.moment(at: end).moved(by: -60) == at(15, 19))
    }

    // MARK: Problems

    @Test("The previous and next problem are the nearest ones, and nil past the last and before the first")
    func neighbouringProblems() {
        let beforeAll = timeline.moment(at: at(14, 5))
        #expect(beforeAll.previousProblem == nil)
        #expect(beforeAll.nextProblem == at(14, 20))

        let between = timeline.moment(at: at(14, 30))
        #expect(between.previousProblem == at(14, 20))
        #expect(between.nextProblem == at(14, 50))

        let afterAll = timeline.moment(at: at(15, 0))
        #expect(afterAll.previousProblem == at(14, 50))
        #expect(afterAll.nextProblem == nil)
    }

    @Test("At the last problem there is a previous one and no next, and the other way round at the first")
    func atTheEndsOfTheProblems() {
        let last = timeline.moment(at: at(14, 50))
        #expect(last.previousProblem == at(14, 20))
        #expect(last.nextProblem == nil)

        let first = timeline.moment(at: at(14, 20))
        #expect(first.previousProblem == nil)
        #expect(first.nextProblem == at(14, 50))
    }

    @Test("A problem within a second of the time is neither previous nor next")
    func aProblemWithinASecondIsSkipped() {
        let problem = at(14, 20)

        let justAfter = timeline.moment(at: problem.addingTimeInterval(0.5))
        #expect(justAfter.previousProblem == nil)
        #expect(justAfter.nextProblem == at(14, 50))

        let justBefore = timeline.moment(at: problem.addingTimeInterval(-0.5))
        #expect(justBefore.previousProblem == nil)
        #expect(justBefore.nextProblem == at(14, 50))

        let twoAfter = timeline.moment(at: problem.addingTimeInterval(2))
        #expect(twoAfter.previousProblem == problem)

        let twoBefore = timeline.moment(at: problem.addingTimeInterval(-2))
        #expect(twoBefore.nextProblem == problem)
    }

    // MARK: Entries either side

    @Test("An entry exactly at the time is before it, and the entries after it follow in order")
    func theBoundaryEntryIsBefore() {
        let moment = timeline.moment(at: at(14, 20))

        #expect(moment.before(3).map(\.id) == [3, 7, 4])
        #expect(moment.after(2).map(\.id) == [8, 5])
        #expect(moment.before(3).last?.run.id == "r2")
    }

    @Test("Before and after give at most the count asked for, and none for a count of zero or less")
    func countsAreBounded() {
        let moment = timeline.moment(at: at(14, 20))

        #expect(moment.before(100).map(\.id) == [1, 2, 3, 7, 4])
        #expect(moment.after(100).map(\.id) == [8, 5, 6])
        #expect(moment.before(0).isEmpty)
        #expect(moment.after(0).isEmpty)
        #expect(moment.before(-1).isEmpty)
        #expect(moment.after(-1).isEmpty)
    }

    @Test("Without a count, five entries are before the time and three after it")
    func defaultCounts() {
        #expect(timeline.moment(at: at(15, 0)).before().count == 5)
        #expect(timeline.moment(at: at(13, 0)).after().count == 3)
    }

    @Test("Before the first entry nothing is before, and after the last nothing is after")
    func theEndsOfTheNight() {
        let early = timeline.moment(at: at(13, 0))
        #expect(early.before(5).isEmpty)
        #expect(early.after(2).map(\.id) == [1, 2])

        let late = timeline.moment(at: at(16, 0))
        #expect(late.after(5).isEmpty)
        #expect(late.before(2).map(\.id) == [5, 6])
    }

    // MARK: Lanes

    @Test("The lanes are the three Acts, and a lane for unstamped events only when a run carries no Act")
    func lanes() {
        #expect(account.lanes == ["author", "build", "land"])

        var withUnstamped = account
        withUnstamped.runs.append(
            Fixture.run("unstamped", act: nil, at: at(14, 40), entries: [Fixture.entry(9, at(14, 40))])
        )
        #expect(withUnstamped.lanes == ["author", "build", "land", nil])
    }
}
