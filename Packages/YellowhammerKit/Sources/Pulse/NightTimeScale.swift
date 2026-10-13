import Foundation

/// A stretch of the Night laid along one axis: the whole Night, or a window of it that a view zoomed to.
///
/// A plain value. It maps times to offsets along an axis of any length and back; the axis itself, and
/// whatever is drawn on it, belong to the view.
public struct NightTimeScale: Equatable, Sendable {
    public var start: Date
    public var end: Date

    /// The whole Night: from its opening to its close, or to a quarter hour past its last entry while it is
    /// open.
    public init(account: NightAccount) {
        start = account.openedAt
        end = account.completedAt ?? (account.runs.map(\.lastAt).max() ?? start).addingTimeInterval(15 * 60)
    }

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var span: TimeInterval { end.timeIntervalSince(start) }

    /// Where `date` falls along an axis `length` long. Zero when the scale spans no time.
    public func position(_ date: Date, length: Double) -> Double {
        guard span > 0 else { return 0 }
        return date.timeIntervalSince(start) / span * length
    }

    /// The time at `offset` along an axis `length` long, kept inside the scale. The start when `length` is
    /// not positive.
    public func date(at offset: Double, length: Double) -> Date {
        guard length > 0 else { return start }
        let fraction = min(max(offset / length, 0), 1)
        return start.addingTimeInterval(span * fraction)
    }

    /// Whether any part of `run`, from its start to its last entry, falls inside the scale.
    public func overlaps(_ run: NightAccount.ActRun) -> Bool {
        run.startedAt <= end && run.lastAt >= start
    }

    /// The axis labels: a tick every five minutes on a scale of 40 minutes or less, every quarter hour on one
    /// of two hours or less, else every hour. Only times strictly between the start and the end.
    public var ticks: [Date] {
        let step: TimeInterval = span <= 40 * 60 ? 300 : span <= 2 * 3_600 ? 900 : 3_600
        return marks(every: step)
    }

    /// The ruler's ticks: a tick every quarter hour, whatever the span. Only times strictly between the start
    /// and the end.
    public var quarterHours: [Date] { marks(every: 900) }

    /// `14:00 – 15:20`.
    public var words: String {
        "\(start.formatted(.dateTime.hour().minute())) \u{2013} \(end.formatted(.dateTime.hour().minute()))"
    }

    /// Ticks `step` apart, counted from the start of the hour that holds the scale's start.
    private func marks(every step: TimeInterval) -> [Date] {
        var tick = Calendar.current.dateInterval(of: .hour, for: start)?.start ?? start
        var marks: [Date] = []
        while tick < end {
            if tick > start { marks.append(tick) }
            tick = tick.addingTimeInterval(step)
        }
        return marks
    }
}
