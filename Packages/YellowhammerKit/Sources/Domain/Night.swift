import Foundation

/// The identity of a Night: the calendar date of its `night_start` (Decision Gates Ruling, G-7),
/// written `YYYY-MM-DD`. Two Acts of one Project that compute the same date are Acts of the same
/// Night, which is how a later Act finds the Night its first Act recorded.
public struct NightStart: RawRepresentable, Hashable, Sendable, CustomStringConvertible, Comparable {
    public let rawValue: String
    public let year: Int
    public let month: Int
    public let day: Int

    /// Fails unless the value is exactly `YYYY-MM-DD` in ASCII digits, with a month of 1–12 and a
    /// day of 1–31. The calendar that produced the date is the one that vouches for the day.
    public init?(rawValue: String) {
        let scalars = Array(rawValue.unicodeScalars)
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-" else { return nil }
        func number(_ range: ClosedRange<Int>) -> Int? {
            var value = 0
            for index in range {
                guard ("0"..."9").contains(scalars[index]) else { return nil }
                value = value * 10 + Int(scalars[index].value - 48)
            }
            return value
        }
        guard
            let year = number(0...3),
            let month = number(5...6), (1...12).contains(month),
            let day = number(8...9), (1...31).contains(day)
        else { return nil }
        self.rawValue = rawValue
        self.year = year
        self.month = month
        self.day = day
    }

    /// Fails unless the month is 1–12, the day 1–31 and the year 0–9999.
    public init?(year: Int, month: Int, day: Int) {
        guard (0...9999).contains(year) else { return nil }
        self.init(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
    }

    public var description: String { rawValue }

    /// Written `YYYY-MM-DD`, so the raw values order as the dates do.
    public static func < (lhs: NightStart, rhs: NightStart) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Every calendar date after `earlier` and before `later`, ascending: empty when they are the
    /// same day, consecutive, or reversed. The `[schedule]` fires every calendar day, so each of
    /// these is a Night that should have opened and did not. Pure date arithmetic, so the calendar's
    /// time zone is immaterial and UTC keeps it so.
    public static func dates(strictlyBetween earlier: NightStart, and later: NightStart) -> [NightStart] {
        guard earlier < later else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard
            let start = calendar.date(from: DateComponents(year: earlier.year, month: earlier.month, day: earlier.day)),
            let end = calendar.date(from: DateComponents(year: later.year, month: later.month, day: later.day))
        else { return [] }
        var absent: [NightStart] = []
        var current = start
        while let next = calendar.date(byAdding: .day, value: 1, to: current), next < end {
            let parts = calendar.dateComponents([.year, .month, .day], from: next)
            if let day = NightStart(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0) {
                absent.append(day)
            }
            current = next
        }
        return absent
    }
}

/// Where a Night is in its life: `opened → closed`. Halting is an event, not a state, and `opened`
/// can be permanent — if the last Act of the Night dies, nothing closes it until the next Night's
/// first Act finds it.
public enum NightState: String, CaseIterable, Sendable {
    case opened
    case closed
}

/// Why a Night closed. The set is closed, and the schema refuses a value outside it.
public enum NightCloseReason: String, CaseIterable, Sendable {
    /// The land firing at `night_end` completed it, whether or not the Cycle landed.
    case nightEnd = "night_end"
    /// The next Night's first Act found this Night left open with no completion, and closed it as it
    /// opened the new Night.
    case openedAndDied = "opened_and_died"
    /// The Project was removed while the Night was open (written by Project removal, a later phase).
    case projectRemoved = "project_removed"
}
