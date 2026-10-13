import Foundation

/// The Night at one time: what each Act was doing, and the entries either side.
///
/// A plain value, cheap to make and to ask. Everything it answers comes from the ``NightTimeline`` it was
/// made from, which is worked out once; a moment only searches it. It never says a run is "running": the
/// account knows a run only by its entries, so it says where the time falls inside or between them.
public struct NightMoment: Sendable {
    public let timeline: NightTimeline
    public let time: Date

    public init(timeline: NightTimeline, time: Date) {
        self.timeline = timeline
        self.time = time
    }

    /// `time` moved by `interval`, kept inside the Night.
    public func moved(by interval: TimeInterval) -> Date {
        min(max(time.addingTimeInterval(interval), timeline.scale.start), timeline.scale.end)
    }

    // MARK: Problems

    /// The time of the last problem more than a second before `time`; nil when there is none.
    public var previousProblem: Date? {
        let threshold = time.addingTimeInterval(-1)
        let end = timeline.problemTimes.endOfLeadingRun { $0 < threshold }
        return timeline.problemTimes[..<end].last
    }

    /// The time of the first problem more than a second after `time`; nil when there is none.
    public var nextProblem: Date? {
        let threshold = time.addingTimeInterval(1)
        let end = timeline.problemTimes.endOfLeadingRun { $0 <= threshold }
        return timeline.problemTimes[end...].first
    }

    // MARK: Acts

    /// What one Act was doing at the time.
    public struct ActState: Identifiable, Sendable {
        /// The Act's name (`author`, `build`, `land`); nil for the lane of events no run stamped.
        public let act: String?
        /// The run the time is inside, or else the Act's last run to start before it; nil before its first.
        public let run: NightAccount.ActRun?
        public let time: Date

        public init(act: String?, run: NightAccount.ActRun?, time: Date) {
            self.act = act
            self.run = run
            self.time = time
        }

        public var id: String { act ?? NightAccount.ActRun.unstampedID }

        /// `Build Act`, or `No Act run` for the lane of events no run stamped.
        public var name: String { NightAccount.name(ofAct: act) }

        /// Whether the time is inside the run, from its start to its last entry. False when there is no run.
        public var isInside: Bool { run.map { time <= $0.lastAt } ?? false }

        /// Where the time falls against the run, in plain words. Never "running": a run's last entry is all
        /// the account knows of it.
        public var words: String {
            guard let run else { return "No run yet" }
            let start = run.startedAt.formatted(.dateTime.hour().minute())
            if isInside {
                return "Inside the \(start) run, \(minutes(since: run.startedAt)) min in; it \(run.outcome.predicate)"
            }
            return "Between runs. The \(start) run \(run.outcome.predicate), \(minutes(since: run.lastAt)) min before"
        }

        private func minutes(since date: Date) -> Int { Int(time.timeIntervalSince(date) / 60) }
    }

    /// One state per lane of the account. For each Act, a run the time is inside wins over a run that merely
    /// started later: a long run is still the Act's run while a stood-down run starts and ends within it.
    public var acts: [ActState] {
        timeline.account.lanes.map { act in
            let started = timeline.account.runs.filter { $0.act == act && $0.startedAt <= time }
            return ActState(act: act, run: started.last { time <= $0.lastAt } ?? started.last, time: time)
        }
    }

    /// The run under the playhead: the last run whose start and last entry the time falls between. Nil when
    /// the time is between runs.
    public var runUnderPlayhead: NightAccount.ActRun? {
        timeline.account.runs.last { $0.startedAt <= time && time <= $0.lastAt }
    }

    // MARK: Entries

    /// The last `count` entries at or before the time, oldest first. An entry exactly at the time is before.
    public func before(_ count: Int = 5) -> [NightTimeline.Item] {
        let end = timeline.items.endOfLeadingRun { $0.entry.occurredAt <= time }
        return Array(timeline.items[..<end].suffix(max(count, 0)))
    }

    /// The first `count` entries after the time, in order.
    public func after(_ count: Int = 3) -> [NightTimeline.Item] {
        let start = timeline.items.endOfLeadingRun { $0.entry.occurredAt <= time }
        return Array(timeline.items[start...].prefix(max(count, 0)))
    }
}

private extension RandomAccessCollection {
    /// The index of the first element `holds` is false for, in a collection where it is true for a leading
    /// run of elements and false for the rest. A binary search, so a sorted collection costs `O(log n)`.
    func endOfLeadingRun(where holds: (Element) -> Bool) -> Index {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = index(low, offsetBy: distance(from: low, to: high) / 2)
            if holds(self[middle]) {
                low = index(after: middle)
            } else {
                high = middle
            }
        }
        return low
    }
}
