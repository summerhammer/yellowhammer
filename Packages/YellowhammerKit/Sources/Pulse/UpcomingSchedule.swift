import Config
import Domain
import Foundation

/// The Night window a Project's `[schedule]` puts next (or around) an instant: when its author Act fires and
/// when the Night-closing land does, both shifted by the Project's stagger offset.
public struct ScheduledNight: Equatable, Sendable {
    public var startsAt: Date
    public var endsAt: Date
    /// True when the window had already opened at the instant it was read: the Night is due, not upcoming.
    public var isOpen: Bool
    /// Whether the Project's three LaunchAgents are loaded in `launchd`. Nil when that was not read, which is
    /// not the same as false: only a read that found them missing says the scheduler is not active.
    public var agentsLoaded: Bool?

    public init(startsAt: Date, endsAt: Date, isOpen: Bool = false, agentsLoaded: Bool? = nil) {
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isOpen = isOpen
        self.agentsLoaded = agentsLoaded
    }
}

/// What the configured `[schedule]` says is coming. Derived from Config alone, never from the Journal.
struct UpcomingSchedule: Equatable, Sendable {
    var nextAct: ScheduledAct?
    var night: ScheduledNight

    /// Nil when the schedule has no firing grid for this Stagger Offset (the load that refuses it says why).
    init?(schedule: Schedule, asOf: Date, calendar: Calendar = .current) {
        guard let firings = try? schedule.firings() else { return nil }
        let offset = schedule.staggerOffsetMinutes
        let startMinutes = schedule.nightStart.minutesSinceMidnight + offset
        let endMinutes = schedule.nightEnd.minutesSinceMidnight + offset
        let length = ((endMinutes - startMinutes) % 1440 + 1440) % 1440

        let today = calendar.startOfDay(for: asOf)
        func date(dayOffset: Int, minutes: Int) -> Date? {
            calendar.date(byAdding: .minute, value: dayOffset * 1440 + minutes, to: today)
        }

        // The window that has not closed yet: today's Night may still be open, or was opened yesterday.
        var window: ScheduledNight?
        for dayOffset in -1...1 {
            guard let start = date(dayOffset: dayOffset, minutes: startMinutes),
                let end = calendar.date(byAdding: .minute, value: length, to: start), end > asOf
            else { continue }
            window = ScheduledNight(startsAt: start, endsAt: end, isOpen: start <= asOf)
            break
        }
        guard let window else { return nil }
        self.night = window

        let acts: [(Act, [TimeOfDay])] = [
            (.author, firings.author), (.build, firings.build), (.land, firings.land)
        ]
        var next: ScheduledAct?
        for dayOffset in 0...1 {
            for (act, times) in acts {
                for time in times {
                    guard let at = date(dayOffset: dayOffset, minutes: time.minutesSinceMidnight), at > asOf
                    else { continue }
                    if next.map({ at < $0.at }) ?? true { next = ScheduledAct(act: act, at: at) }
                }
            }
        }
        self.nextAct = next
    }
}
