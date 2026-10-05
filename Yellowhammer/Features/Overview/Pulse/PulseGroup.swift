import Domain
import Pulse
import SwiftUI

/// The Pulse's five groups, in the ruled order Needs you → Now → Feature → Tonight / last Night →
/// Health. The summary strip and the cards both iterate it, so neither can reorder the groups.
enum PulseGroup: String, CaseIterable, Identifiable {
    case needsYou = "Needs you"
    case now = "Now"
    case feature = "Feature"
    case night = "Tonight / last Night"
    case health = "Health"

    var id: Self { self }
    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .now: "clock.fill"
        case .feature: "flag.fill"
        case .night: "moon.stars.fill"
        case .health: "stethoscope"
        }
    }

    /// The group's anchor colour, a fill under `onStyle` or a wash behind its card.
    var style: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .needsYou: .attention
        case .now: .active
        case .feature: .accent
        case .night: .info
        case .health: .warning
        }
        return style
    }

    /// The foreground placed on `style` as a fill.
    var onStyle: some ShapeStyle {
        let style: ThemeShapeStyle<Color> = switch self {
        case .needsYou: .onAttention
        case .now: .onActive
        case .feature: .onAccent
        case .night: .onInfo
        case .health: .onWarning
        }
        return style
    }

    // One line per group saying what it holds, beside its title. A value the Journal read leaves nil is
    // stated as unknown, never invented.

    static func summary(of needsYou: NeedsYou) -> String {
        let waiting = needsYou.waitingOnYouCount
        let blocked = needsYou.cards.count - waiting
        return needsYou.cards.isEmpty ? "Nothing needs you" : "\(waiting) Waiting on You · \(blocked) Blocked"
    }

    static func summary(of now: Now) -> String {
        if let runningAct = now.runningAct {
            return "\(runningAct.act.rawValue) running · \(now.attempts.count) Attempt(s)"
        }
        return now.attempts.isEmpty ? now.statusLine : "\(now.status.rawValue) · \(now.attempts.count) running"
    }

    static func summary(of feature: FeatureInFlight?) -> String {
        guard let feature else { return "No Feature in flight" }
        return [feature.id, feature.rollupState?.rawValue ?? "rollup state unknown"].joined(separator: " · ")
    }

    static func summary(of night: NightPulse?) -> String {
        night?.state.rawValue ?? "No Night yet"
    }

    static func summary(of health: [HealthFlag]?) -> String {
        guard let health else { return "yh doctor not read" }
        return health.isEmpty ? "No health flags" : "\(health.count) flagged"
    }
}

// MARK: For display

extension Now {
    /// `idle — next Act author 01:30`; without a scheduled Act the line says it is unknown.
    var statusLine: String {
        "\(status.rawValue) — \(nextActLine)"
    }

    /// `next Act author 01:30`, or a stated unknown (the next Act is not in the Journal).
    var nextActLine: String {
        guard let nextAct else { return "next Act unknown" }
        return "next Act \(nextAct.act.rawValue) \(nextAct.at.formatted(date: .omitted, time: .shortened))"
    }
}

extension FeatureInFlight {
    /// Cards done and total across every Repo Lane.
    var cardProgress: (done: Int, total: Int) {
        (lanes.map(\.cardsDone).reduce(0, +), lanes.map(\.cardsTotal).reduce(0, +))
    }
}
