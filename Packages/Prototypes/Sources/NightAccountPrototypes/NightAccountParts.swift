#if DEBUG
import AppKit
import Pulse
import SwiftUI

// What every Night account variant shares: the theme colours, how a run's outcome looks, the time scale the
// lanes are drawn on, and the Inspector's Night header and facts.

/// The app's theme colours, mirrored from `Theme+Defaults.swift` because this package never links the app.
enum NightTheme {
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let attention = Color(light: 0xFF9500, dark: 0xFF9F0A)
    static let success = Color(light: 0x71C171, dark: 0x408140)
    static let info = Color(light: 0x46B8DA, dark: 0x269ABC)
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

// MARK: - Runs

extension NightAccount.RunOutcome {
    /// How the run ended, in plain words, as the app's Inspector words it. Never "running".
    var words: String {
        switch self {
        case .ended: "ended"
        case .idle(let reason): "idle \u{2014} \(reason)"
        case .incomplete(let reason): "could not complete \u{2014} \(reason)"
        case .stoodDown: "stood down"
        case .notEnded: "not ended"
        }
    }

    /// The outcome alone, without its reason.
    var shortWords: String {
        switch self {
        case .ended: "ended"
        case .idle: "idle"
        case .incomplete: "could not complete"
        case .stoodDown: "stood down"
        case .notEnded: "not ended"
        }
    }

    var symbol: String {
        switch self {
        case .ended: "checkmark.circle.fill"
        case .idle: "moon.zzz"
        case .incomplete: "exclamationmark.triangle.fill"
        case .stoodDown: "arrow.uturn.backward.circle"
        case .notEnded: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ended: NightTheme.success
        case .idle, .stoodDown: NightTheme.neutral
        case .incomplete: NightTheme.error
        // Not the attention colour: that rings a problem.
        case .notEnded: NightTheme.info
        }
    }

    /// A run that did nothing: it found no work, or another run held the Project.
    var isQuiet: Bool {
        switch self {
        case .idle, .stoodDown: true
        case .ended, .incomplete, .notEnded: false
        }
    }
}

extension NightAccount.ActRun {
    /// `Build Act`, or `No Act run` for the events no run stamped.
    var actName: String { act.map { "\($0.capitalized) Act" } ?? "No Act run" }

    /// `Build Act · 14:00`.
    var title: String { "\(actName) \u{00B7} \(startedAt.formatted(.dateTime.hour().minute()))" }

    /// The time of the run's last entry, or its start.
    var lastAt: Date { entries.last?.occurredAt ?? startedAt }
}

/// A stretch of the Night laid along one axis: the whole Night, or a window of it a variant zoomed to.
struct NightTimeScale: Equatable {
    var start: Date
    var end: Date

    /// The whole Night: from its opening to its close, or to a quarter hour past its last entry while it is
    /// open.
    init(account: NightAccount) {
        start = account.openedAt
        end = account.completedAt ?? (account.runs.map(\.lastAt).max() ?? start).addingTimeInterval(15 * 60)
    }

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    var span: TimeInterval { end.timeIntervalSince(start) }

    /// Where `date` falls along an axis `length` long, as a fraction of it.
    func position(_ date: Date, length: CGFloat) -> CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat(date.timeIntervalSince(start) / span) * length
    }

    /// The time at `offset` along an axis `length` long, kept inside the scale.
    func date(at offset: CGFloat, length: CGFloat) -> Date {
        guard length > 0 else { return start }
        let fraction = min(max(offset / length, 0), 1)
        return start.addingTimeInterval(span * Double(fraction))
    }

    func overlaps(_ run: NightAccount.ActRun) -> Bool {
        run.startedAt <= end && run.lastAt >= start
    }

    /// A tick on every hour, or every quarter hour or five minutes once the scale is short enough.
    var ticks: [Date] {
        let step: TimeInterval = span <= 40 * 60 ? 300 : span <= 2 * 3_600 ? 900 : 3_600
        var tick = Calendar.current.dateInterval(of: .hour, for: start)?.start ?? start
        var ticks: [Date] = []
        while tick < end {
            if tick > start { ticks.append(tick) }
            tick = tick.addingTimeInterval(step)
        }
        return ticks
    }

    /// `14:00 – 15:20`.
    var words: String {
        "\(start.formatted(.dateTime.hour().minute())) \u{2013} \(end.formatted(.dateTime.hour().minute()))"
    }
}

extension NightAccount {
    /// Author, Build and Land, and a lane for unstamped events when there are any.
    var lanes: [String?] {
        let acts: [String?] = ["author", "build", "land"]
        return runs.contains { $0.act == nil } ? acts + [nil] : acts
    }

    /// Every problem entry, with the run that recorded it.
    var problems: [(run: ActRun, entry: Entry)] {
        runs.flatMap { run in run.entries.filter(\.isProblem).map { (run, $0) } }
    }

    var title: String { "Night of \(nightStart)" }

    /// `13:45 – 18:30`, or `13:45 – open`.
    var span: String {
        let start = openedAt.formatted(.dateTime.hour().minute())
        let end = completedAt?.formatted(.dateTime.hour().minute()) ?? "open"
        return "\(start) \u{2013} \(end)"
    }
}

extension NightAccount.Entry {
    var time: String { occurredAt.formatted(.dateTime.hour().minute().second()) }
}

// MARK: - Shared views

/// A small capsule, the app's `PulseCountBadge`.
struct NightBadge: View {
    let text: String
    var tint: Color = NightTheme.neutral

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

/// The Night's state and mode as badges.
struct NightStateBadges: View {
    let account: NightAccount

    var body: some View {
        HStack(spacing: 6) {
            NightBadge(
                text: account.state.rawValue, tint: account.state == .running ? NightTheme.success : NightTheme.info
            )
            if account.mode == .rehearsal {
                NightBadge(text: "rehearsal")
            }
        }
    }
}

/// The Inspector's header, as `InspectorPane` draws it: the kind over the title, the badges beside.
struct NightInspectorHeader: View {
    let account: NightAccount

    var body: some View {
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
}

/// The Night's facts as labelled rows, and the Inspector's one way out.
struct NightFactsInspector: View {
    let account: NightAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NightInspectorHeader(account: account)
                    NightFactRows(account: account)
                }
                .padding(16)
            }
            NightWayOut(account: account)
        }
    }
}

struct NightFactRows: View {
    let account: NightAccount

    var body: some View {
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
}

/// The Night Card's way out and the note under it, the foot of every Night Inspector.
struct NightWayOut: View {
    let account: NightAccount
    @Environment(\.openNightDestination) private var open

    var body: some View {
        VStack(spacing: 8) {
            if let card = account.nightCard {
                Button {
                    open(card.url)
                } label: {
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

/// One entry: the time, a problem mark, the headline over the detail.
struct NightEntryLine: View {
    let entry: NightAccount.Entry
    var showsSeconds = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(showsSeconds ? entry.time : entry.occurredAt.formatted(.dateTime.hour().minute()))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: showsSeconds ? 58 : 40, alignment: .leading)
            if entry.isProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(NightTheme.attention)
                    .accessibilityLabel("Problem")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.headline)
                if let detail = entry.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}

/// The Night Card's way out, routed through the environment so a preview only records it.
extension EnvironmentValues {
    @Entry var openNightDestination: (URL) -> Void = { _ in }
}
#endif
