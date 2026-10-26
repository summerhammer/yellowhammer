#if DEBUG
import Domain
import Pulse
import SwiftUI

// Round three: the Project's current status as a colour box at the top of the Pulse, so it is found at a
// glance (G1) and said in words (G2). Every head shows the same `PulseCondition` — a status word, a symbol,
// one line, and a jump to the group that explains it — and differs only in how the colour is drawn. The
// cards below are the shipped tinted cards, with no summary strip.

/// How the status head draws its colour.
enum PulseStatusHead: String, CaseIterable, Identifiable {
    /// A pixelated gradient: square cells that dissolve downward.
    case pixels = "Pixel Fade"
    /// A mesh gradient of the status colour and two neighbours.
    case mesh = "Mesh Aurora"
    /// Mesh Aurora made lighter in light appearance, with the icon on a solid tile.
    case meshMist = "Mesh Mist"
    /// A horizontal gradient whose stops are the share of each state, with a legend.
    case spectrum = "Spectrum"

    var id: Self { self }
}

extension EnvironmentValues {
    /// The head `PulseSectionStyle.statusHead` draws. Set from `PulseDesign.head`.
    @Entry var pulseStatusHead: PulseStatusHead = .pixels
}

// MARK: - Condition

/// The one thing to know about the Project right now, loudest first: Waiting on You, then Blocked Cards,
/// then a failed Act, Health flags and a starved Night, then working, then a running or done Night, then
/// idle. It is derived from the Project's own Pulse alone.
struct PulseCondition {
    let title: String
    let line: String
    let symbol: String
    let color: Color
    /// Two neighbouring colours, for the mesh and the pixel field.
    let companions: [Color]
    /// The group whose card explains the status.
    let group: PulseGroup

    // One branch per status, in loudness order; splitting it would hide the order.
    // swiftlint:disable:next cyclomatic_complexity
    init(project: ProjectSnapshot, palette: PulsePalette) {
        let pulse = project.pulse
        let waiting = pulse.needsYou.waitingOnYouCount
        let blocked = pulse.needsYou.cards.count { $0.state == .blocked }
        let flags = pulse.health ?? []
        if waiting > 0 {
            let blockedPart = blocked > 0 ? " · \(blocked) Blocked" : ""
            self.init(
                "Needs you", "\(waiting) Waiting on You\(blockedPart)", "hand.raised.fill",
                palette.needsYou, [palette.blocked, palette.health], .needsYou
            )
        } else if blocked > 0 {
            self.init(
                "Blocked", blocked == 1 ? "1 Card Blocked" : "\(blocked) Cards Blocked", "exclamationmark.octagon.fill",
                palette.blocked, [palette.needsYou, palette.night], .needsYou
            )
        } else if let failure = pulse.night?.firstFailureHeadline {
            self.init(
                "Act failed", failure, "xmark.octagon.fill", palette.blocked, [palette.health, palette.night], .night
            )
        } else if !flags.isEmpty {
            self.init(
                "Health flagged", flags.count == 1 ? "1 flag from yh doctor" : "\(flags.count) flags from yh doctor",
                "stethoscope", palette.health, [palette.needsYou, palette.accent], .health
            )
        } else if let night = pulse.night, night.state == .starved {
            self.init(
                "Night starved", night.verdictLine ?? "No Card was ready to work on", "moon.zzz.fill",
                palette.needsYou, [palette.night, palette.health], .night
            )
        } else if pulse.now.status == .working {
            let attempts = pulse.now.attempts.count
            let line = switch attempts {
            case 0: pulse.now.runningAct.map { "\($0.act.rawValue) Act running" } ?? PulseFormat.nowLine(pulse.now)
            case 1: "1 Attempt running"
            default: "\(attempts) Attempts running"
            }
            self.init("Working", line, "gearshape.2.fill", palette.working, [palette.accent, palette.landed], .now)
        } else if let night = pulse.night, night.state == .running {
            self.init(
                "Night running", PulseFormat.nowLine(pulse.now), "moon.stars.fill",
                palette.night, [palette.working, palette.accent], .now
            )
        } else if let night = pulse.night, night.state == .done {
            self.init(
                "Night done", night.verdictLine ?? "Started \(PulseFormat.time(night.startedAt))",
                "checkmark.seal.fill", palette.night, [palette.landed, palette.accent], .night
            )
        } else {
            self.init("Idle", PulseFormat.nowLine(pulse.now), "moon.fill", .gray, [palette.night, .gray], .now)
        }
    }

    private init(
        _ title: String, _ line: String, _ symbol: String, _ color: Color, _ companions: [Color], _ group: PulseGroup
    ) {
        self.title = title
        self.line = line
        self.symbol = symbol
        self.color = color
        self.companions = companions
        self.group = group
    }
}

/// A count of one state, for the heads that draw the mix rather than only the loudest state.
struct PulseTally: Identifiable {
    let label: String
    let count: Int
    let color: Color
    var id: String { label }

    /// Every non-zero state, loudest first. Cards done and remaining come from the Feature in flight.
    static func tallies(of pulse: PulseSnapshot, palette: PulsePalette) -> [PulseTally] {
        let blocked = pulse.needsYou.cards.count { $0.state == .blocked }
        let running = pulse.now.attempts.count
        let progress = pulse.feature.map(PulseFormat.cardProgress) ?? (done: 0, total: 0)
        return [
            PulseTally(label: "Waiting on You", count: pulse.needsYou.waitingOnYouCount, color: palette.needsYou),
            PulseTally(label: "Blocked", count: blocked, color: palette.blocked),
            PulseTally(label: "Health flags", count: pulse.health?.count ?? 0, color: palette.health),
            PulseTally(label: "Running", count: running, color: palette.working),
            PulseTally(label: "Done", count: progress.done, color: palette.landed),
            PulseTally(
                label: "To do", count: max(0, progress.total - progress.done - running), color: .gray.opacity(0.5)
            )
        ]
        .filter { $0.count >= 1 }
    }
}

// MARK: - Sections

/// The status head over the tinted cards in the ruled order. The head's button jumps to its group's card.
struct PulseStatusHeadSections: View {
    let context: PulseContext
    @Environment(\.pulseStatusHead) private var head
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        let condition = PulseCondition(project: context.project, palette: palette)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PulseStatusHeadView(head: head, context: context, condition: condition) { group in
                        withAnimation { proxy.scrollTo(group, anchor: .top) }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(PulseGroup.allCases) { group in
                            PulseTintedCard(group: group, context: context).id(group)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }
}

/// One head, drawn the way `head` says.
struct PulseStatusHeadView: View {
    let head: PulseStatusHead
    let context: PulseContext
    let condition: PulseCondition
    let jump: (PulseGroup) -> Void
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        switch head {
        case .pixels: bleeding { PulsePixelField(colors: [condition.color] + condition.companions) }
        case .mesh: bleeding { PulseMesh(color: condition.color, companions: condition.companions) }
        case .meshMist:
            bleeding(iconOnSurface: true) {
                PulseMesh(color: condition.color, companions: condition.companions, isMist: true)
            }
        case .spectrum: spectrum
        }
    }

    private var headline: PulseConditionHeadline {
        PulseConditionHeadline(project: context.project, condition: condition, jump: jump)
    }

    private func headline(iconOnSurface: Bool) -> PulseConditionHeadline {
        PulseConditionHeadline(project: context.project, condition: condition, iconOnSurface: iconOnSurface, jump: jump)
    }

    /// The headline over a background that runs edge to edge and up under the toolbar.
    private func bleeding<Background: View>(
        iconOnSurface: Bool = false, @ViewBuilder _ background: () -> Background
    ) -> some View {
        headline(iconOnSurface: iconOnSurface)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { background().ignoresSafeArea(edges: .top).backgroundExtensionEffect() }
    }

    private var spectrum: some View {
        let tallies = PulseTally.tallies(of: context.pulse, palette: palette)
        return VStack(alignment: .leading, spacing: 14) {
            headline
            PulseTallyLegend(tallies: tallies)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            PulseSpectrum(tallies: tallies, fallback: condition.color)
                .ignoresSafeArea(edges: .top)
                .backgroundExtensionEffect()
        }
    }
}

// MARK: - Headline

/// The status in words: the Project, the status word, its line, and a jump to the group that explains it.
/// Every head carries it, so colour is never the only signal.
struct PulseConditionHeadline: View {
    let project: ProjectSnapshot
    let condition: PulseCondition
    /// The icon on a solid tile in the window background, so it reads over any colour behind it.
    var iconOnSurface = false
    let jump: (PulseGroup) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: condition.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(condition.color)
                .frame(width: 52, height: 52)
                .background(condition.color.opacity(0.16), in: .rect(cornerRadius: 12))
                .background {
                    if iconOnSurface {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.background)
                            .shadow(color: condition.color.opacity(0.25), radius: 6, y: 2)
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name + " · " + (project.repos.count == 1 ? "1 Repo" : "\(project.repos.count) Repos"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(condition.title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                Text(condition.line)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button { jump(condition.group) } label: {
                Label("Show \(condition.group.title)", systemImage: "arrow.down")
            }
            .buttonStyle(.glass)
            .foregroundStyle(.primary)
        }
    }
}
#endif
