#if DEBUG
import Domain
import Pulse
import SwiftUI

// Building blocks the composed variants share: the five groups, the ways out, formatting, and the rows
// every section style arranges differently. A row only renders snapshot values and calls `PulseActions`.

/// The Pulse's five groups, in the ruled order.
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

    /// One line saying what the group holds, used where the group is collapsed or summarised.
    func summary(of project: ProjectSnapshot) -> String {
        let pulse = project.pulse
        switch self {
        case .needsYou:
            let waiting = pulse.needsYou.waitingOnYouCount
            let blocked = pulse.needsYou.cards.count - waiting
            return pulse.needsYou.cards.isEmpty ? "Nothing needs you" : "\(waiting) Waiting on You · \(blocked) Blocked"
        case .now:
            let attempts = pulse.now.attempts.count
            return attempts > 0 ? "\(pulse.now.status.rawValue) · \(attempts) running" : PulseFormat.nowLine(pulse.now)
        case .feature:
            return pulse.feature.map {
                [$0.issueIDForDisplay ?? $0.id, $0.rollupState?.rawValue].compactMap { $0 }.joined(separator: " · ")
            } ?? "No Feature in flight"
        case .night:
            return pulse.night?.state.rawValue ?? "No Night yet"
        case .health:
            guard let health = pulse.health else { return "Not read" }
            return health.isEmpty ? "Healthy" : "\(health.count) flagged"
        }
    }
}

/// Every way out of a Pulse element. `inspect` opens the Inspector; `open` leaves for the Night Card,
/// Settings, Linear or GitHub. Neither is a triage gesture.
struct PulseActions {
    /// What the Inspector currently shows, so a row can mark itself selected.
    let inspected: PulseSelection?
    let inspect: @MainActor (PulseSelection) -> Void
    let open: @MainActor (PulseDestination) -> Void
}

/// What one section style needs to render the selected Project's Pulse.
struct PulseContext {
    let project: ProjectSnapshot
    let asOf: Date
    let actions: PulseActions
    var pulse: PulseSnapshot { project.pulse }
}

extension EnvironmentValues {
    /// A prototype-only action that is not a `PulseDestination` (e.g. re-reading the Journal). The
    /// Playground records it beside the ways out.
    @Entry var pulsePrototypeAction: @MainActor (String) -> Void = { _ in }
}

enum PulseFormat {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func elapsed(since start: Date, asOf: Date) -> String {
        Duration.seconds(asOf.timeIntervalSince(start)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    static func nextAct(_ now: Now) -> String? {
        now.nextAct.map { "next Act \($0.act.rawValue) \(time($0.at))" }
    }

    /// The Now group's stated line, e.g. `idle — next Act author 01:30`.
    static func nowLine(_ now: Now) -> String {
        [now.status.rawValue, nextAct(now)].compactMap { $0 }.joined(separator: " — ")
    }

    /// A route rendered as `cli/model/effort`, split into labelled parts for display; nil when it is
    /// not in that shape.
    static func routeParts(_ route: String) -> [(label: String, value: String)]? {
        let parts = route.split(separator: "/").map(String.init)
        guard parts.count == 3 else { return nil }
        return zip(["CLI", "Model", "Effort"], parts).map { ($0, $1) }
    }

    static func cardProgress(_ feature: FeatureInFlight) -> (done: Int, total: Int) {
        (feature.lanes.map(\.cardsDone).reduce(0, +), feature.lanes.map(\.cardsTotal).reduce(0, +))
    }
}

// MARK: - Small parts

/// A state badge: a coloured dot and a label on a neutral capsule, so colour never carries text contrast.
struct PulseBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(.quaternary, in: .capsule)
    }
}

struct PulseStatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// A group's stated absence — never a blank.
struct PulseAbsence: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.secondary)
    }
}

/// The group's title with its icon tinted by the palette.
struct PulseGroupLabel: View {
    let group: PulseGroup
    var font: Font = .headline
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        Label {
            Text(group.title).font(font)
        } icon: {
            Image(systemName: group.systemImage).foregroundStyle(palette.color(for: group))
        }
    }
}

extension View {
    /// Marks the row the Inspector shows. The padding is applied whether or not it is selected, so
    /// selecting a row never moves it.
    func pulseRowHighlight(_ isSelected: Bool, tint: Color) -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(isSelected ? tint.opacity(0.16) : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
    }
}

struct PulsePullRequestButton: View {
    let chip: PullRequestChip
    let action: () -> Void
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(palette.color(for: chip.state))
                Text(["#\(chip.number)", chip.state?.rawValue].compactMap { $0 }.joined(separator: " "))
                    .monospacedDigit()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Open pull request #\(chip.number) on GitHub")
    }
}

// MARK: - Rows

struct PulseCardRow: View {
    let card: DecisionCard
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: card.state == .blocked ? "exclamationmark.octagon.fill" : "questionmark.bubble.fill")
                .foregroundStyle(palette.color(for: card.state))
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).lineLimit(1)
                Text("\(card.issueIDForDisplay ?? card.id) · \(card.repo)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PulseBadge(text: card.blockReason?.rawValue ?? card.state.rawValue, color: palette.color(for: card.state))
        }
    }
}

struct PulseAttemptRow: View {
    let attempt: RunningAttempt
    let asOf: Date
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.2.fill").foregroundStyle(palette.working)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(attempt.cardIDForDisplay ?? attempt.cardID)  \(attempt.workCardTitle)").lineLimit(1)
                Text([attempt.repo, attempt.status].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(PulseFormat.elapsed(since: attempt.startedAt, asOf: asOf)).monospacedDigit()
                Text("Round \(attempt.round)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PulseLaneRow: View {
    let lane: RepoLaneSnapshot
    let context: PulseContext
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Button { context.actions.inspect(.repo(lane.repo)) } label: {
                Label(lane.repo, systemImage: "shippingbox").lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            ProgressView(value: Double(lane.cardsDone), total: Double(max(lane.cardsTotal, 1)))
                .frame(width: 64)
                .tint(palette.color(for: lane.state))
            Text("\(lane.cardsDone)/\(lane.cardsTotal)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            PulseBadge(text: lane.state.rawValue, color: palette.color(for: lane.state))
            if let chip = lane.pullRequest {
                PulsePullRequestButton(chip: chip) {
                    context.actions.open(.pullRequest(chip.url))
                }
            }
        }
        .pulseRowHighlight(context.actions.inspected == .repo(lane.repo), tint: palette.accent)
    }
}

struct PulseDispositionCounts: View {
    let night: NightPulse
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            ForEach(night.cardsByDisposition) { entry in
                Label {
                    Text("\(entry.count) \(entry.disposition.rawValue)").monospacedDigit()
                } icon: {
                    PulseStatusDot(color: palette.color(for: entry.disposition), size: 7)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct PulseHealthRow: View {
    let flag: HealthFlag
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.health)
            VStack(alignment: .leading, spacing: 1) {
                Text(flag.kind.rawValue.prefix(1).uppercased() + flag.kind.rawValue.dropFirst())
                Text(flag.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "gearshape").foregroundStyle(.secondary).help("Open the Project's Settings")
        }
    }
}

/// The Project's name heading the main area, so the Pulse always says whose it is.
struct PulseHeader: View {
    let project: ProjectSnapshot
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name).font(.largeTitle.bold()).lineLimit(2)
            HStack(spacing: 6) {
                PulseStatusDot(color: palette.color(for: project.status))
                Text(project.status.rawValue)
                Text("·")
                Text(project.repos.count == 1 ? "1 Repo" : "\(project.repos.count) Repos")
            }
            .foregroundStyle(.secondary)
        }
    }
}
#endif
