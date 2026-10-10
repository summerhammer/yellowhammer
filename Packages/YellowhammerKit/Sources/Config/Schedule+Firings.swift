import Domain

/// The wall-clock firing grid a Project's `[schedule]` implies, in whole minutes since midnight. Pure
/// arithmetic — no `Date`/`Calendar` — so it is not affected by DST and can be tested without a clock.
extension Schedule {
    /// This repo's local choice (not the spec's): the per-Project offset that keeps sibling Projects'
    /// LaunchAgents from firing in the same minute. With the default 15-minute `build_every_minutes`,
    /// five Projects staggered by 3 minutes each interleave without ever sharing a minute.
    public static let staggerStepMinutes = 3

    /// How much later than its land tick each periodic build fires (Build Firing Offset Ruling
    /// 2026-10-10): a build and a land Act started in the same second race for the Project's Lease and
    /// one stands down. With `build_every_minutes == 1` there is no room for the offset, so it is zero.
    static let buildFiringOffsetMinutes = 1

    /// The minutes after the Night-closing land (`night_end + o`) at which the three flush firings fire
    /// (Transient Board Failure Ruling 2026-10-09 item 6; OQ155 (2)): 15 minutes, 1 hour and 3 hours.
    public static let flushFiringOffsetsMinutes = [15, 60, 180]

    /// One Project's author, build and land firings, each in firing order and deduplicated.
    ///
    /// `build` fires one minute after each periodic land tick (see `buildFiringOffsetMinutes`), so the
    /// two never share a minute — except that with `build_every_minutes == 1` they do, and that the last
    /// build can fall on the Night-closing land's minute when the window length minus one is a multiple
    /// of `build_every_minutes`.
    public struct ScheduledFirings: Equatable, Sendable {
        public let author: [TimeOfDay]
        public let build: [TimeOfDay]
        /// Every firing the land LaunchAgent carries: the periodic ticks, the Night-closing land and the
        /// flush firings. Setup builds the plist from this.
        public let land: [TimeOfDay]
        /// The flush firings alone, a subset of ``land`` that shares no time with the rest of it.
        public let flush: [TimeOfDay]

        /// The land firings that belong to the Night itself: ``land`` without the flush firings, which fall
        /// after `night_end` and so are not among the Night's firing instants.
        public var landWithinNight: [TimeOfDay] { land.filter { !flush.contains($0) } }
    }

    /// A `[schedule]` this Project's stagger offset cannot be scheduled from.
    public struct FiringGridError: Error, Equatable, Sendable {
        public let message: String
    }

    /// The firing grid for `staggerIndex`'s position among a machine's Projects (sorted ascending by
    /// `ProjectID`; see ``ScheduledJob``). Offsets `night_start`/`night_end`/every periodic firing by
    /// `staggerIndex * staggerStepMinutes` (`o`), wrapping at midnight. For each `k` with
    /// `o + k × build_every_minutes` inside the window, land fires at
    /// `night_start + o + k × build_every_minutes` and build one minute later; author fires at
    /// `night_start + o` and the Night-closing land at `night_end + o`, followed by the flush firings
    /// (``flushFiringOffsetsMinutes`` after it).
    ///
    /// Throws when the offset consumes the whole Night window (`offset >= L`) or when the window spans
    /// a full 24 hours (`night_start == night_end`): a 24-hour window has no land firing that belongs to
    /// the Night it closes, since that firing would land at the next Night's `night_start` instead.
    public func firings(staggerIndex: Int) throws(FiringGridError) -> ScheduledFirings {
        let offset = staggerIndex * Self.staggerStepMinutes
        let nightStartMinutes = nightStart.minutesSinceMidnight
        let nightEndMinutes = nightEnd.minutesSinceMidnight
        let rawLength = (nightEndMinutes - nightStartMinutes) % 1440
        let length = rawLength == 0 ? 1440 : (rawLength < 0 ? rawLength + 1440 : rawLength)

        guard length != 1440 else {
            throw FiringGridError(
                message: "a 24-hour Night window (night_start \(nightStart), night_end \(nightEnd)) has no "
                    + "land firing that belongs to the Night it closes"
            )
        }
        guard offset < length else {
            throw FiringGridError(
                message: "stagger offset \(offset)m at index \(staggerIndex) is not inside the "
                    + "\(length)m Night window (night_start \(nightStart), night_end \(nightEnd))"
            )
        }

        func time(_ minutesFromNightStart: Int) -> TimeOfDay {
            let absolute = ((nightStartMinutes + minutesFromNightStart) % 1440 + 1440) % 1440
            return TimeOfDay(uncheckedHour: absolute / 60, minute: absolute % 60)
        }

        func deduplicated(_ times: [TimeOfDay]) -> [TimeOfDay] {
            var seen = Set<TimeOfDay>()
            var result: [TimeOfDay] = []
            for time in times where seen.insert(time).inserted {
                result.append(time)
            }
            return result
        }

        let author = [time(offset)]

        var buildOffsets: [Int] = []
        var multiplier = 1
        while offset + multiplier * buildEveryMinutes < length {
            buildOffsets.append(offset + multiplier * buildEveryMinutes)
            multiplier += 1
        }
        // Build fires one minute after the land tick it shares a `k` with, so the two Acts never start in
        // the same second and race for the Project's Lease. Every `k` keeps its firing: the shift never
        // adds, drops or merges one, even when the last build lands on the Night-closing land's minute.
        let buildShift = buildEveryMinutes == 1 ? 0 : Self.buildFiringOffsetMinutes
        let build = deduplicated(buildOffsets.map { time($0 + buildShift) })
        let nightLand = deduplicated(buildOffsets.map(time) + [time(offset + length)])

        // Lead draft, pending sponsor (Transient Board Failure Ruling, "Drafted by the lead"): a flush
        // firing that would fall at or after the next Night's `night_start + o` is not generated, so a
        // short-gap or daytime schedule never flushes inside the next Night. Measured from `night_end + o`
        // the next Night's `night_start + o` is `1440 - length` minutes away, whatever `o` is.
        let gap = 1440 - length
        let flushOffsets = Self.flushFiringOffsetsMinutes.filter { $0 < gap }
        let taken = Set(nightLand)
        let flush = deduplicated(flushOffsets.map { time(offset + length + $0) }).filter { !taken.contains($0) }

        return ScheduledFirings(
            author: deduplicated(author), build: build, land: deduplicated(nightLand + flush), flush: flush
        )
    }
}

extension Schedule.FiringGridError: CustomStringConvertible {
    public var description: String { message }
}
