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
        // A returned Feature counts as Waiting on You; it is never a Blocked Card.
        let waiting = needsYou.waitingOnYouCount
        let blocked = needsYou.cards.count { $0.state == .blocked }
        return needsYou.isEmpty ? "Nothing needs you" : "\(waiting) Waiting on You · \(blocked) Blocked"
    }

    static func summary(of now: Now) -> String {
        if let runningAct = now.runningAct {
            return "\(runningAct.act.rawValue) running · \(now.attempts.count) Attempt(s)"
        }
        return now.attempts.isEmpty ? now.statusLine : "\(now.status.rawValue) · \(now.attempts.count) running"
    }

    static func summary(of feature: FeatureInFlight?, stack: UnmergedFeatureStack = .empty) -> String {
        guard let feature else {
            // Proposed amendment, yellowhammer-spec#132: a Feature awaiting merge is not "in flight".
            if stack.isEmpty { return "No Feature in flight" }
            return stack.unmergedFeaturesMax == nil ? stack.awaitingText : "Awaiting merge · \(stack.countText)"
        }
        let rollUp = feature.rollupState?.rawValue ?? "rollup state unknown"
        var parts = [feature.issueIDForDisplay ?? feature.id, rollUp]
        if !stack.isEmpty { parts.append("\(stack.count) awaiting merge") }
        return parts.joined(separator: " · ")
    }

    static func summary(of night: NightPulse?, scheduled: ScheduledNight? = nil) -> String {
        if let night { return night.state.rawValue }
        return scheduled?.startLine ?? "No Night yet"
    }

    static func summary(of health: [HealthFlag]?) -> String {
        guard let health else { return "yh doctor not read" }
        return health.isEmpty ? "No flags" : "\(health.count) flagged"
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

extension ScheduledNight {
    private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// `starts 00:30`, or `window open` once the window has opened with no Night recorded.
    var startLine: String { isOpen ? "window open" : "starts \(Self.time(startsAt))" }

    /// `Upcoming Night starts 00:30 (00:30 – 06:30)`.
    var detailLine: String {
        let window = "\(Self.time(startsAt)) – \(Self.time(endsAt))"
        return isOpen
            ? "Night window is open until \(Self.time(endsAt)); no Night recorded yet"
            : "Upcoming Night starts \(Self.time(startsAt)) (\(window))"
    }

    /// Set only when `launchctl` was read and the Project's LaunchAgents are not all loaded.
    var schedulerNotice: String? {
        agentsLoaded == false ? "LaunchAgents not installed: run yh setup --install-jobs" : nil
    }
}

extension FeatureInFlight {
    /// Cards done and total across every Repo Lane.
    var cardProgress: (done: Int, total: Int) {
        (lanes.map(\.cardsDone).reduce(0, +), lanes.map(\.cardsTotal).reduce(0, +))
    }
}

extension FeatureInFlight {
    /// The Feature's Journal state as a badge colour: a returned Feature needs the Operator.
    var stateStyle: ThemeShapeStyle<Color> {
        state == "returned" ? .attention : .neutral
    }
}

extension VerificationCounts {
    /// `4 of 22 clauses unmet` (`, 1 unresolved` when any, `, 1 not checked` when any), or `all 22 clauses met`.
    var summary: String {
        guard unmet + unresolved + notChecked > 0 else { return "all \(total) clauses met" }
        let unresolvedNote = unresolved > 0 ? ", \(unresolved) unresolved" : ""
        let notCheckedNote = notChecked > 0 ? ", \(notChecked) not checked" : ""
        return "\(unmet) of \(total) clauses unmet\(unresolvedNote)\(notCheckedNote)"
    }
}
