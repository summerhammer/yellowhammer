#if DEBUG
import Domain
import Foundation
import Pulse

// `NightAccount` fixtures, worded the way `NightAccount+Wording.swift` words Journal events, so a variant
// shows what the real read would give it. Nothing here reads a Journal.

/// The Nights a variant can be shown with.
enum NightAccountScenario: String, CaseIterable, Identifiable {
    case hostCrash = "Host crash"
    case quiet = "Quiet Night"
    case openRehearsal = "Open rehearsal"

    var id: String { rawValue }

    var account: NightAccount {
        switch self {
        case .hostCrash: NightAccountFixtures.hostCrash
        case .quiet: NightAccountFixtures.quiet
        case .openRehearsal: NightAccountFixtures.openRehearsal
        }
    }
}

enum NightAccountFixtures {
    /// The Night in the 2026-10-11 screenshot: the Feature authored, both Cards blocked by host crashes, Linear
    /// unreachable for a while, then a long run of Acts with nothing to do.
    static let hostCrash: NightAccount = {
        var builder = RunBuilder()
        builder.run(.author, at: "13:45:05", .ended) { run in
            run.entry("13:45:05", "Night opened")
            run.entry("13:45:05", "Author Act started")
            run.entry("13:45:41", "Selected the Feature \u{201C}Night verdict wording\u{201D}")
            run.entry("13:52:18", "Authored the Feature \u{201C}Night verdict wording\u{201D}", "YLH-342, 2 Cards")
            run.entry("13:52:19", "Author Act ended")
        }
        builder.run(.build, at: "14:00:02", .ended) { run in
            run.entry("14:00:02", "Build Act started")
            run.entry("14:00:04", "Repo Lane yellowhammer started", "2 Cards")
            run.entry("14:00:09", "YLH-343 moved from todo to inProgress")
            run.entry("14:41:30", "YLH-343: Attempt ended", "crashed (host crash) on claude-code \u{00B7} opus")
            run.entry("14:41:31", "YLH-343 moved from inProgress to blocked", "Block Reason: hostCrash")
            run.entry("14:41:35", "YLH-344 moved from todo to inProgress")
            run.entry("15:12:02", "YLH-344: Attempt ended", "crashed (host crash) on codex \u{00B7} gpt-5")
            run.entry("15:12:03", "YLH-344 moved from inProgress to blocked", "Block Reason: hostCrash")
            run.entry("15:12:04", "Repo Lane yellowhammer failed", "2 Cards blocked by host crashes", problem: true)
            run.entry("15:12:05", "Build Act ended")
        }
        builder.run(.land, at: "14:15:01", .idle(reason: NightWordsFixture.cycleUnfinished)) { run in
            run.idle("14:15:01", act: "Land", reason: NightWordsFixture.cycleUnfinished)
        }
        for time in ["14:30:01", "15:00:02"] {
            builder.run(.build, at: time, .stoodDown) { run in
                run.entry(time, "Build Act stood down \u{2014} another run holds the Project", "Held by the build Act")
            }
        }
        for time in ["14:45:01", "15:15:01"] {
            builder.run(.land, at: time, .idle(reason: NightWordsFixture.cycleUnfinished)) { run in
                run.idle(time, act: "Land", reason: NightWordsFixture.cycleUnfinished)
            }
        }
        builder.run(.build, at: "16:30:02", .incomplete(reason: NightWordsFixture.offline)) { run in
            run.entry("16:30:02", "Build Act started")
            run.entry("16:30:33", "Halted \u{2014} Linear was unreachable", problem: true)
            run.entry("16:30:33", "Linear was not updated", "Move YLH-343 to Needs You: \(NightWordsFixture.offline)",
                      problem: true)
            run.entry("16:30:34", "Build Act could not complete", NightWordsFixture.offline, problem: true)
        }
        builder.run(.land, at: "16:45:01", .idle(reason: NightWordsFixture.cycleUnfinished)) { run in
            run.entry("16:45:02", "Reached Linear")
            run.idle("16:45:03", act: "Land", reason: NightWordsFixture.cycleUnfinished)
        }
        builder.quietStretch(from: 15, to: 16, buildReason: NightWordsFixture.nothingToBuild)
        builder.quietStretch(from: 17, to: 18, buildReason: NightWordsFixture.nothingToBuild)
        builder.run(.land, at: "18:30:04", .idle(reason: NightWordsFixture.cycleUnfinished)) { run in
            run.idle("18:30:04", act: "Land", reason: NightWordsFixture.cycleUnfinished)
            run.entry("18:30:07", "Night closed", "reached Night end")
        }
        return NightAccount(
            id: 41,
            nightStart: "2026-10-11",
            mode: .real,
            state: .done,
            openedAt: NightClock.date("13:45:05"),
            completedAt: NightClock.date("18:30:07"),
            closeReason: "reached Night end",
            nightCard: NightWordsFixture.nightCard,
            runs: builder.runs
        )
    }()

    /// A Night where everything worked: both Cards done, the Cycle landed and verified. No problems.
    static let quiet: NightAccount = {
        var builder = RunBuilder()
        builder.run(.author, at: "13:45:03", .idle(reason: NightWordsFixture.cardsLeft)) { run in
            run.entry("13:45:03", "Night opened")
            run.idle("13:45:04", act: "Author", reason: NightWordsFixture.cardsLeft)
        }
        builder.run(.build, at: "14:00:02", .ended) { run in
            run.entry("14:00:02", "Build Act started")
            run.entry("14:00:04", "Repo Lane yellowhammer started", "2 Cards")
            run.entry("14:00:09", "YLH-343 moved from todo to inProgress")
            run.entry("14:38:51", "YLH-343: Check passed", "Exit status 0")
            run.entry("14:38:52", "YLH-343: Attempt ended", "succeeded on claude-code \u{00B7} opus")
            run.entry("14:38:53", "YLH-343 moved from inProgress to inReview")
            run.entry("14:39:00", "YLH-344 moved from todo to inProgress")
            run.entry("15:20:12", "YLH-344: Check passed", "Exit status 0")
            run.entry("15:20:13", "YLH-344: Attempt ended", "succeeded on codex \u{00B7} gpt-5")
            run.entry("15:20:14", "YLH-344 moved from inProgress to inReview")
            run.entry("15:20:15", "Repo Lane yellowhammer ended", "2 Cards run, 0 skipped")
            run.entry("15:20:16", "Build Act ended")
        }
        for time in ["14:30:01", "15:00:02"] {
            builder.run(.build, at: time, .stoodDown) { run in
                run.entry(time, "Build Act stood down \u{2014} another run holds the Project", "Held by the build Act")
            }
        }
        builder.quietStretch(from: 15, to: 16, buildReason: NightWordsFixture.nothingToBuild)
        builder.run(.land, at: "17:15:01", .ended) { run in
            run.entry("17:15:01", "Land Act started")
            run.entry("17:24:40", "The Cycle landed")
            run.entry("17:31:02", "The Feature was verified", "6 met, 0 unmet, 0 unresolved")
            run.entry("17:31:03", "Land Act ended")
        }
        builder.run(.land, at: "18:30:02", .idle(reason: NightWordsFixture.alreadyLanded)) { run in
            run.idle("18:30:02", act: "Land", reason: NightWordsFixture.alreadyLanded)
            run.entry("18:30:05", "Night closed", "reached Night end")
        }
        return NightAccount(
            id: 40,
            nightStart: "2026-10-11",
            mode: .real,
            state: .done,
            openedAt: NightClock.date("13:45:03"),
            completedAt: NightClock.date("18:30:05"),
            closeReason: "reached Night end",
            nightCard: NightWordsFixture.nightCard,
            runs: builder.runs
        )
    }()

    /// A rehearsal Night still open, whose last Build Act run was killed: it has no closing event.
    static let openRehearsal: NightAccount = {
        var builder = RunBuilder()
        builder.run(.author, at: "13:45:05", .ended) { run in
            run.entry("13:45:05", "Night opened")
            run.entry("13:45:05", "Author Act started")
            run.entry("13:46:12", "Authored nothing \u{2014} a Feature is already in flight", "YLH-342")
            run.entry("13:46:13", "Author Act ended")
        }
        builder.run(.build, at: "14:00:02", .ended) { run in
            run.entry("14:00:02", "Build Act started")
            run.entry("14:00:03", "Reclaimed an expired Lease", "Left by a build Act run", problem: true)
            run.entry("14:00:04", "Repo Lane yellowhammer started", "1 Card")
            run.entry("14:00:09", "YLH-344 moved from todo to inProgress")
            run.entry("14:00:10", "Build Act ended")
        }
        builder.run(.land, at: "14:15:01", .idle(reason: NightWordsFixture.cycleUnfinished)) { run in
            run.idle("14:15:01", act: "Land", reason: NightWordsFixture.cycleUnfinished)
        }
        builder.run(.build, at: "14:30:02", .notEnded) { run in
            run.entry("14:30:02", "Build Act started")
            run.entry("14:30:04", "Repo Lane yellowhammer started", "1 Card")
        }
        return NightAccount(
            id: 42,
            nightStart: "2026-10-12",
            mode: .rehearsal,
            state: .running,
            openedAt: NightClock.date("13:45:05"),
            completedAt: nil,
            closeReason: nil,
            nightCard: nil,
            runs: builder.runs
        )
    }()
}

/// Recurring words, as the wording file gives them.
private enum NightWordsFixture {
    static let cycleUnfinished = "the Cycle still has unfinished Cards"
    static let nothingToBuild = "the Cycle has nothing left to build"
    static let cardsLeft = "Cards are still left to work, so there is nothing to author"
    static let alreadyLanded = "the Cycle has already landed"
    static let offline = "The Internet connection appears to be offline. (NSURLErrorDomain -1009)"
    static let nightCard = LinearIssueLink(
        identifier: "YLH-341",
        url: URL(string: "https://linear.app/yellowhammer/issue/YLH-341")! // swiftlint:disable:this force_unwrapping
    )
}

/// Every fixture time is on the Night of 2026-10-11, in the Mac's time zone, so it reads as written.
enum NightClock {
    static func date(_ time: String) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let components = DateComponents(
            year: 2026, month: 10, day: 11, hour: parts[0], minute: parts[1], second: parts.count > 2 ? parts[2] : 0
        )
        return Calendar.current.date(from: components) ?? .now
    }
}

/// Builds runs in the order the Journal would record their first event.
private struct RunBuilder {
    enum ActName: String { case author, build, land }

    private(set) var runs: [NightAccount.ActRun] = []
    private var nextEntryID: Int64 = 1

    struct Entries {
        fileprivate var entries: [NightAccount.Entry] = []
        fileprivate var nextID: Int64

        mutating func entry(_ time: String, _ headline: String, _ detail: String? = nil, problem: Bool = false) {
            entries.append(.init(
                id: nextID, occurredAt: NightClock.date(time), headline: headline, detail: detail, isProblem: problem
            ))
            nextID += 1
        }

        mutating func idle(_ time: String, act: String, reason: String) {
            entry(time, "\(act) Act idle \u{2014} nothing to do", reason)
        }
    }

    mutating func run(
        _ act: ActName, at time: String, _ outcome: NightAccount.RunOutcome, _ fill: (inout Entries) -> Void
    ) {
        var entries = Entries(nextID: nextEntryID)
        fill(&entries)
        nextEntryID = entries.nextID
        runs.append(.init(
            id: "run-\(runs.count + 1)", act: act.rawValue, startedAt: NightClock.date(time), outcome: outcome,
            entries: entries.entries
        ))
        runs.sort { $0.startedAt < $1.startedAt }
    }

    /// A Build Act on the hour and half hour and a Land Act a quarter past each, for every hour in the range,
    /// each with nothing to do, up to the Night end at 18:30. A slot another run already fills is skipped.
    mutating func quietStretch(from firstHour: Int, to lastHour: Int, buildReason: String) {
        for hour in firstHour...lastHour {
            for (minute, act) in [(0, ActName.build), (15, .land), (30, .build), (45, .land)] {
                let time = String(format: "%02d:%02d:0%d", hour, minute, act == .build ? 2 : 1)
                let startedAt = NightClock.date(time)
                if startedAt >= NightClock.date("18:30:00") || runs.contains(where: { $0.startedAt == startedAt }) {
                    continue
                }
                let reason = act == .build ? buildReason : NightWordsFixture.cycleUnfinished
                run(act, at: time, .idle(reason: reason)) { run in
                    run.idle(time, act: act.rawValue.capitalized, reason: reason)
                }
            }
        }
    }
}
#endif
