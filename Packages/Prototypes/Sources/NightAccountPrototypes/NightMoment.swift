#if DEBUG
import Pulse
import SwiftUI

// The idea the Editor draws: a playhead you move along the Night, and the Night at that moment — what each
// Act was doing, and the entries either side of it. `NightMoment` works the moment out, apart from the view.

/// The Night at one moment.
struct NightMoment {
    let account: NightAccount
    let time: Date

    var scale: NightTimeScale { NightTimeScale(account: account) }

    /// Where the playhead opens: the Night's first problem, else its opening.
    static func opening(of account: NightAccount) -> Date {
        account.problems.map(\.entry.occurredAt).min() ?? account.openedAt
    }

    /// `at` moved by `interval`, kept inside the Night.
    func moved(by interval: TimeInterval) -> Date {
        min(max(time.addingTimeInterval(interval), scale.start), scale.end)
    }

    // MARK: Problems

    var problemTimes: [Date] { account.problems.map(\.entry.occurredAt).sorted() }
    var previousProblem: Date? { problemTimes.last { $0 < time.addingTimeInterval(-1) } }
    var nextProblem: Date? { problemTimes.first { $0 > time.addingTimeInterval(1) } }

    // MARK: Acts

    /// What one Act was doing at the moment.
    struct ActState: Identifiable {
        let act: String?
        /// The run the moment is inside, or else the Act's last run before it; nil before its first.
        let run: NightAccount.ActRun?
        let time: Date

        var id: String { act ?? "unstamped" }
        var name: String { act.map { "\($0.capitalized) Act" } ?? "No Act run" }
        var isInside: Bool { run.map { time <= $0.lastAt } ?? false }
        var tint: Color { run?.outcome.tint ?? NightTheme.neutral }

        /// Never "running": a run's last entry is all the account knows of it.
        var words: String {
            guard let run else { return "No run yet" }
            let start = run.startedAt.formatted(.dateTime.hour().minute())
            if isInside {
                return "Inside the \(start) run, \(minutes(since: run.startedAt)) min in; it \(run.outcome.words)"
            }
            return "Between runs. The \(start) run \(run.outcome.words), \(minutes(since: run.lastAt)) min before"
        }

        private func minutes(since date: Date) -> Int { Int(time.timeIntervalSince(date) / 60) }
    }

    var acts: [ActState] {
        account.lanes.map { act in
            let started = account.runs.filter { $0.act == act && $0.startedAt <= time }
            // A long run the moment is inside wins over a stood-down run that started after it.
            return ActState(act: act, run: started.last { time <= $0.lastAt } ?? started.last, time: time)
        }
    }

    /// The run under the playhead, which the lanes mark as selected.
    var runUnderPlayhead: NightAccount.ActRun? {
        account.runs.last { $0.startedAt <= time && time <= $0.lastAt }
    }

    // MARK: Entries

    /// One entry with the run that recorded it.
    struct Item: Identifiable {
        let run: NightAccount.ActRun
        let entry: NightAccount.Entry
        var id: Int64 { entry.id }
    }

    private var items: [Item] {
        account.runs
            .flatMap { run in run.entries.map { Item(run: run, entry: $0) } }
            .sorted { $0.entry.occurredAt < $1.entry.occurredAt }
    }

    /// The entries up to the moment, the last `count` of them, oldest first.
    func before(_ count: Int = 5) -> [Item] {
        Array(items.filter { $0.entry.occurredAt <= time }.suffix(count))
    }

    /// The entries after the moment, the first `count` of them.
    func after(_ count: Int = 3) -> [Item] {
        Array(items.filter { $0.entry.occurredAt > time }.prefix(count))
    }
}

extension Date {
    /// `15:12:04`.
    var clockTime: String { formatted(.dateTime.hour().minute().second()) }
}

extension View {
    /// A playhead control VoiceOver can adjust, five minutes a step.
    func nightPlayheadAccessibility(account: NightAccount, playhead: Binding<Date>) -> some View {
        accessibilityElement()
            .accessibilityLabel("Playhead")
            .accessibilityValue(playhead.wrappedValue.formatted(.dateTime.hour().minute()))
            .accessibilityAdjustableAction { direction in
                let moment = NightMoment(account: account, time: playhead.wrappedValue)
                playhead.wrappedValue = moment.moved(by: direction == .increment ? 300 : -300)
            }
    }
}
#endif
