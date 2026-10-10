import Foundation

extension Schedule {
    /// Whether a scheduled land Act started at `now` is a flush firing of the Night `window` describes: at
    /// or after the first flush minute (`night_end + o + 15 min`, `o` being the Stagger Offset of
    /// `staggerIndex`) and before the next Night's `night_start`.
    ///
    /// Every land firing runs the same `yh land --project <id>`, so the Act classifies itself from the
    /// clock. A land between `night_end + o` and the first flush minute is the Night-closing land and is
    /// not a flush firing. The caller excludes a forced land and any rehearsal land.
    public func isFlushFiring(
        at now: Date, in window: NightWindow, staggerIndex: Int, calendar: Calendar = .current
    ) -> Bool {
        let minutes = staggerIndex * Self.staggerStepMinutes + (Self.flushFiringOffsetsMinutes.first ?? 0)
        guard let first = calendar.date(byAdding: .minute, value: minutes, to: window.end),
            let nextNightStart = calendar.date(byAdding: .day, value: 1, to: window.start)
        else { return false }
        return now >= first && now < nextNightStart
    }
}
