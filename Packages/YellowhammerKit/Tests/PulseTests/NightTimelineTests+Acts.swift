import Foundation
import Testing

@testable import Pulse

// What each Act was doing at a time, the run under the playhead, and how a run and its outcome read in plain
// words. Never "running": the account knows a run only by its entries.

private typealias Fixture = NightTimelineFixture

private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    Fixture.clock(hour, minute, second)
}

extension NightTimelineTests {
    private func state(_ act: String?, at time: Date) throws -> NightMoment.ActState {
        try #require(timeline.moment(at: time).acts.first { $0.act == act })
    }

    // MARK: Acts

    @Test("A run the time is inside wins over a stood-down run of the same Act that started after it")
    func aLongRunWinsOverALaterStoodDownRun() throws {
        // r2 is the build Act's 14:10 run, to 14:55. r4 is its 14:30 run, which stood down and ended at 14:30.
        let build = try state("build", at: at(14, 35))

        #expect(build.run?.id == "r2")
        #expect(build.isInside)
        #expect(build.words == "Inside the \(Fixture.words(at(14, 10))) run, 25 min in; it ended")
        #expect(try state("build", at: at(14, 30, 30)).run?.id == "r2")
    }

    @Test("Before an Act's first run it has no run, and says so")
    func beforeAnActsFirstRun() throws {
        let build = try state("build", at: at(14, 5))

        #expect(build.run == nil)
        #expect(!build.isInside)
        #expect(build.words == "No run yet")
        #expect(try state("land", at: at(14, 10)).words == "No run yet")
    }

    @Test("Between runs the Act's last run to start is reported, with how long before it ended")
    func betweenRuns() throws {
        let author = try state("author", at: at(14, 30))

        #expect(author.run?.id == "r1")
        #expect(!author.isInside)
        #expect(author.words == "Between runs. The \(Fixture.words(at(14, 0))) run ended, 25 min before")
    }

    @Test("Between runs, the last run to start is the one reported, even a stood-down one")
    func betweenRunsReportsTheLastToStart() throws {
        let build = try state("build", at: at(15, 0))

        #expect(build.run?.id == "r4")
        #expect(!build.isInside)
        #expect(build.words == "Between runs. The \(Fixture.words(at(14, 30))) run stood down, 30 min before")
    }

    @Test("Inside a run is worded with how long into it the time is, and the outcome with its reason")
    func insideARun() throws {
        let land = try state("land", at: at(14, 15))

        #expect(land.run?.id == "r3")
        #expect(land.isInside)
        let start = Fixture.words(at(14, 15))
        #expect(land.words == "Inside the \(start) run, 0 min in; it was idle \u{2014} nothing to land")
    }

    @Test("Inside a run that recorded no end, the sentence says so and never that it is running")
    func insideARunWithNoEnd() {
        let run = Fixture.run(
            "r5", act: "build", at: at(14, 40), .notEnded,
            entries: [Fixture.entry(9, at(14, 40)), Fixture.entry(10, at(14, 52))]
        )
        let build = NightMoment.ActState(act: "build", run: run, time: at(14, 46))

        #expect(build.isInside)
        #expect(build.words == "Inside the \(Fixture.words(at(14, 40))) run, 6 min in; it recorded no end")
        #expect(!build.words.contains("running"))
    }

    @Test("Between runs, an idle run is worded as having been idle, with its reason")
    func betweenRunsAfterAnIdleRun() throws {
        let land = try state("land", at: at(14, 20))

        #expect(land.run?.id == "r3")
        #expect(!land.isInside)
        let start = Fixture.words(at(14, 15))
        #expect(land.words == "Between runs. The \(start) run was idle \u{2014} nothing to land, 5 min before")
    }

    @Test("There is one state per lane, named for the Act, and the unstamped lane is named for what it is")
    func onePerLane() throws {
        let moment = timeline.moment(at: at(14, 35))

        #expect(moment.acts.map(\.id) == ["author", "build", "land"])
        #expect(moment.acts.map(\.name) == ["Author Act", "Build Act", "Land Act"])

        var withUnstamped = account
        withUnstamped.runs.append(
            Fixture.run("unstamped", act: nil, at: at(14, 40), entries: [Fixture.entry(9, at(14, 40))])
        )
        let unstamped = try #require(NightTimeline(account: withUnstamped).moment(at: at(14, 41)).acts.last)

        #expect(unstamped.id == "unstamped")
        #expect(unstamped.name == "No Act run")
        #expect(unstamped.run?.id == "unstamped")
    }

    @Test("No Act's words ever say a run is running")
    func neverRunning() {
        var time = at(13, 50)
        while time <= at(15, 30) {
            for state in timeline.moment(at: time).acts {
                #expect(!state.words.contains("running"))
            }
            time = time.addingTimeInterval(60)
        }
    }

    // MARK: The run under the playhead

    @Test("The run under the playhead is the last run whose start and last entry the time falls between")
    func theRunUnderThePlayhead() {
        #expect(timeline.moment(at: at(14, 35)).runUnderPlayhead?.id == "r2")
        #expect(timeline.moment(at: at(14, 15)).runUnderPlayhead?.id == "r3")
        #expect(timeline.moment(at: at(14, 30)).runUnderPlayhead?.id == "r4")
        #expect(timeline.moment(at: at(14, 0)).runUnderPlayhead?.id == "r1")
        #expect(timeline.moment(at: at(14, 7)).runUnderPlayhead == nil)
        #expect(timeline.moment(at: at(15, 10)).runUnderPlayhead == nil)
    }

    // MARK: Runs

    @Test("A run's last moment is its last entry, or its start when it has none")
    func lastAt() {
        #expect(account.runs.map(\.lastAt) == [at(14, 5), at(14, 55), at(14, 15), at(14, 30)])
        #expect(Fixture.run("empty", act: "build", at: at(14, 40), entries: []).lastAt == at(14, 40))
    }

    @Test("A run is named for its Act and titled with the time it started")
    func runNames() throws {
        let build = try #require(account.runs.first { $0.id == "r2" })
        let unstamped = Fixture.run("unstamped", act: nil, at: at(14, 40), entries: [])

        #expect(build.actName == "Build Act")
        #expect(build.title == "Build Act \u{00B7} \(Fixture.words(at(14, 10)))")
        #expect(unstamped.actName == "No Act run")
        #expect(unstamped.title == "No Act run \u{00B7} \(Fixture.words(at(14, 40)))")
    }

    @Test("An outcome is worded plainly, with its reason, and never as running")
    func outcomeWords() {
        let cases = [
            OutcomeCase(outcome: .ended, words: "ended", short: "ended", isQuiet: false),
            OutcomeCase(
                outcome: .idle(reason: "nothing to do"), words: "idle \u{2014} nothing to do", short: "idle",
                isQuiet: true
            ),
            OutcomeCase(
                outcome: .incomplete(reason: "Linear was unreachable"),
                words: "could not complete \u{2014} Linear was unreachable", short: "could not complete",
                isQuiet: false
            ),
            OutcomeCase(outcome: .stoodDown, words: "stood down", short: "stood down", isQuiet: true),
            OutcomeCase(outcome: .notEnded, words: "not ended", short: "not ended", isQuiet: false)
        ]

        for expected in cases {
            #expect(expected.outcome.words == expected.words)
            #expect(expected.outcome.shortWords == expected.short)
            #expect(expected.outcome.isQuiet == expected.isQuiet)
            #expect(!expected.outcome.words.contains("running"))
        }
    }

    @Test("An outcome's predicate is a verb phrase that follows 'it' or 'the 14:00 run', and never says running")
    func outcomePredicates() {
        let predicates: [(outcome: NightAccount.RunOutcome, predicate: String)] = [
            (.ended, "ended"),
            (.idle(reason: "nothing to do"), "was idle \u{2014} nothing to do"),
            (.incomplete(reason: "Linear was unreachable"), "could not complete \u{2014} Linear was unreachable"),
            (.stoodDown, "stood down"),
            (.notEnded, "recorded no end")
        ]

        for expected in predicates {
            #expect(expected.outcome.predicate == expected.predicate)
            #expect(!expected.outcome.predicate.contains("running"))
        }
    }
}

/// One outcome, and how it reads in full, how it reads alone, and whether it is a run that did nothing.
private struct OutcomeCase {
    let outcome: NightAccount.RunOutcome
    let words: String
    let short: String
    let isQuiet: Bool
}
