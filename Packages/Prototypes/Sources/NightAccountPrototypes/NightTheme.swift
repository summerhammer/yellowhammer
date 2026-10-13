#if DEBUG
import AppKit
import Domain
import Pulse
import SwiftUI

// What every Timeline design shares: the theme colours, how a run's outcome looks, and the Inspector beside
// the editor. The words a run or an Act is given come from `Pulse`, as they do in the app.

/// The app's theme colours, mirrored from `Theme+Defaults.swift` because this package never links the app.
enum NightTheme {
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let attention = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let success = Color(light: 0x71C171, dark: 0x408140)
    static let info = Color(light: 0x46B8DA, dark: 0x269ABC)
    /// Rings a problem, as the app's `.warning` does.
    static let warning = Color(light: 0xFFCC00, dark: 0xFFD60A)
    static let error = Color(light: 0xFF3B30, dark: 0xFF453A)
    static let neutral = Color(light: 0x8E8E93, dark: 0x98989D)
    /// Primary at 5%, the fill behind boxed groups.
    static let surface = Color.primary.opacity(0.05)
}

extension Color {
    /// A colour that follows the appearance, as the app's ThemeKit tokens do.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Outcomes

extension NightAccount.RunOutcome {
    /// Never the warning colour: that rings a problem, and a run with one is ringed separately.
    var tint: Color {
        switch self {
        case .ended: NightTheme.success
        case .idle, .stoodDown: NightTheme.neutral
        case .incomplete: NightTheme.error
        case .notEnded: NightTheme.info
        }
    }
}

extension NightMoment.ActState {
    /// The tint of the run the time is in or after; neutral before the Act's first run.
    var tint: Color { run?.outcome.tint ?? NightTheme.neutral }
}

extension NightPulseState {
    var tint: Color {
        switch self {
        case .running: NightTheme.success
        case .done: NightTheme.info
        case .starved: NightTheme.attention
        }
    }
}

extension NightAccount.ActRun {
    /// Whether `time` falls inside the run, from its start to its last entry.
    func contains(_ time: Date) -> Bool { startedAt <= time && time <= lastAt }
}

extension NightAccount {
    var title: String { "Night of \(nightStart)" }

    /// The lane's short label: `Build`, or `No Act`.
    static func laneLabel(_ act: String?) -> String { act.map { $0.capitalized } ?? "No Act" }
}

extension NightTimeline {
    /// The runs in `act`'s lane that fall inside `scale`, in the order they started.
    func runs(in act: String?, within scale: NightTimeScale) -> [NightAccount.ActRun] {
        account.runs.filter { $0.act == act && scale.overlaps($0) }
    }
}

extension NightTimeScale {
    /// Ticks `step` apart, counted from the start of the hour that holds the scale's start, strictly inside it.
    func marks(every step: TimeInterval) -> [Date] {
        var tick = Calendar.current.dateInterval(of: .hour, for: start)?.start ?? start
        var marks: [Date] = []
        while tick < end {
            if tick > start { marks.append(tick) }
            tick = tick.addingTimeInterval(step)
        }
        return marks
    }

    /// Whether `time` falls inside the scale.
    func contains(_ time: Date) -> Bool { start <= time && time <= end }
}

extension Date {
    /// `15:12:04`.
    var clockTime: String { formatted(.dateTime.hour().minute().second()) }
    /// `15:12`.
    var shortClock: String { formatted(.dateTime.hour().minute()) }
}

// MARK: - Shared views

/// A small capsule, the app's `PulseCountBadge`.
struct NightBadge: View {
    let text: String
    var tint: Color = NightTheme.neutral

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
    }
}

/// The Night's state and mode as badges.
struct NightStateBadges: View {
    let account: NightAccount

    var body: some View {
        HStack(spacing: 6) {
            NightBadge(text: account.state.rawValue, tint: account.state.tint)
            if account.mode == .rehearsal {
                NightBadge(text: "rehearsal")
            }
        }
    }
}

/// The problem mark macOS uses: a dark exclamation mark on the warning colour.
struct NightProblemMark: View {
    var size: CGFloat = 10

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.black.opacity(0.75), NightTheme.warning)
            .accessibilityLabel("Problem")
    }
}

/// The Inspector beside the editor, as the app draws it: the Night's header, its facts and its one way out.
struct NightFactsInspector: View {
    let account: NightAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    facts
                }
                .padding(16)
            }
            wayOut
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.title2)
                .foregroundStyle(NightTheme.info)
                .frame(width: 44, height: 44)
                .background(NightTheme.info.opacity(0.14), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("NIGHT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(account.title).font(.title3.weight(.semibold))
                NightStateBadges(account: account)
            }
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            row("Opened", account.openedAt.formatted(date: .abbreviated, time: .standard))
            Divider()
            row("Closed", account.completedAt?.formatted(date: .abbreviated, time: .standard) ?? "not closed")
            if let reason = account.closeReason {
                Divider()
                row("Close reason", reason)
            }
            Divider()
            row("Act runs", "\(account.runs.count)")
            Divider()
            row("Problems", "\(account.problemCount)")
        }
        .padding(.horizontal, 12)
        .background(NightTheme.surface, in: .rect(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(.vertical, 8)
    }

    private var wayOut: some View {
        VStack(spacing: 8) {
            if let card = account.nightCard {
                Button {} label: {
                    Label("Open \(card.identifier) in Linear", systemImage: "arrow.up.forward.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            Text("The Night\u{2019}s account, as this Project\u{2019}s Journal recorded it. Triage happens in Linear.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
    }
}

extension View {
    /// The strip as one adjustable element for VoiceOver, five minutes a step, as the app's ruler is.
    func nightPlayheadAccessibility(timeline: NightTimeline, playhead: Binding<Date>) -> some View {
        accessibilityElement()
            .accessibilityLabel("Playhead")
            .accessibilityValue(playhead.wrappedValue.shortClock)
            .accessibilityAdjustableAction { direction in
                playhead.wrappedValue = timeline.moment(at: playhead.wrappedValue)
                    .moved(by: direction == .increment ? 300 : -300)
            }
    }
}
#endif
