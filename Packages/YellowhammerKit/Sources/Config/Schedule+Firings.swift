import Domain

/// The wall-clock firing grid a Project's `[schedule]` implies, in whole minutes since midnight. Pure
/// arithmetic — no `Date`/`Calendar` — so it is not affected by DST and can be tested without a clock.
extension Schedule {
    /// This repo's local choice (not the spec's): the per-Project offset that keeps sibling Projects'
    /// LaunchAgents from firing in the same minute. With the default 15-minute `build_every_minutes`,
    /// five Projects staggered by 3 minutes each interleave without ever sharing a minute.
    public static let staggerStepMinutes = 3

    /// One Project's author, build and land firings, each in firing order and deduplicated.
    public struct ScheduledFirings: Equatable, Sendable {
        public let author: [TimeOfDay]
        public let build: [TimeOfDay]
        public let land: [TimeOfDay]
    }

    /// A `[schedule]` this Project's stagger offset cannot be scheduled from.
    public struct FiringGridError: Error, Equatable, Sendable {
        public let message: String
    }

    /// The firing grid for `staggerIndex`'s position among a machine's Projects (sorted ascending by
    /// `ProjectID`; see ``ScheduledJob``). Offsets `night_start`/`night_end`/every build firing by
    /// `staggerIndex * staggerStepMinutes`, wrapping at midnight.
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
        let build = deduplicated(buildOffsets.map(time))
        let land = deduplicated(buildOffsets.map(time) + [time(offset + length)])

        return ScheduledFirings(author: deduplicated(author), build: build, land: land)
    }
}

extension Schedule.FiringGridError: CustomStringConvertible {
    public var description: String { message }
}
