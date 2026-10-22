import Foundation

/// When a CLI that refused for a usage limit may be tried again.
///
/// The vendor's reset text is only a hint. It is honoured when it names its own zone
/// (`resets 1:50am (Europe/Kiev)`), because that is an absolute instant, and never when it is a
/// bare wall-clock time (`try again at 2:55 PM`), whose zone would be a guess. Whatever the hint
/// says, the delay stays inside `minimumDelay...maximumDelay`, so a garbled hint cannot park a
/// CLI for the rest of the Night or retry it at once.
public enum UsageLimitReset {
    public static let defaultDelay: TimeInterval = 30 * 60
    public static let minimumDelay: TimeInterval = 5 * 60
    public static let maximumDelay: TimeInterval = 8 * 60 * 60
    /// A firing this close to the end of a backoff already counts as past it, so a cadence slot
    /// is not lost to seconds.
    public static let cadenceGrace: TimeInterval = 60

    /// The instant the backoff ends: the zoned reset time when the hint has one, else the default
    /// delay, clamped to the bounds.
    public static func until(resetHint: String?, now: Date) -> Date {
        let target = resetHint.flatMap { resetsAt(from: $0, now: now) }
            ?? now.addingTimeInterval(defaultDelay)
        let earliest = now.addingTimeInterval(minimumDelay)
        let latest = now.addingTimeInterval(maximumDelay)
        return min(max(target, earliest), latest)
    }

    /// The next occurrence after `now` of a `resets <h[:mm]>(am|pm) (<IANA zone>)` hint, or nil
    /// when the hint has no zone or does not match.
    public static func resetsAt(from hint: String, now: Date) -> Date? {
        let pattern = #/
            resets \s+ (?<hour> \d{1,2}) (?: : (?<minute> \d{2}) )? \s* (?<meridiem> [AaPp][Mm])
            \s* \( (?<zone> [A-Za-z0-9_+\-]+ (?: / [A-Za-z0-9_+\-]+ )* ) \)
            /#
        guard let match = hint.firstMatch(of: pattern),
              let zone = TimeZone(identifier: String(match.output.zone)),
              let hour12 = Int(match.output.hour), (1...12).contains(hour12) else { return nil }
        let minute = match.output.minute.flatMap { Int($0) } ?? 0
        guard (0..<60).contains(minute) else { return nil }
        let isPM = match.output.meridiem.lowercased() == "pm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour12 % 12 + (isPM ? 12 : 0), minute: minute, second: 0),
            matchingPolicy: .nextTime
        )
    }
}
