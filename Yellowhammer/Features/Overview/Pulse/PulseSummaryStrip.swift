import Domain
import Pulse
import SwiftUI

/// Five figures, one per group in the ruled order, each a button that jumps to the group's card.
struct PulseSummaryStrip: View {
    let pulse: PulseSnapshot
    let jump: (PulseGroup) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(PulseGroup.allCases) { group in
                Button { jump(group) } label: {
                    PulseSummaryFigure(group: group, pulse: pulse)
                }
                .buttonStyle(.plain)
                .help("Jump to \(group.title)")
            }
        }
        .accessibilityIdentifier("pulse-summary-strip")
    }
}

/// One group's figure: its name, one value, and a caption saying what the value counts.
private struct PulseSummaryFigure: View {
    let group: PulseGroup
    let pulse: PulseSnapshot

    var body: some View {
        let (value, caption) = figure
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(group == .night ? "Night" : group.title)
            } icon: {
                Image(systemName: group.systemImage).foregroundStyle(group.style)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        // A zero minimum width: a scaling or unbounded minimum here makes the split view renegotiate
        // the detail column's minimum size without end.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(.surface, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pulse-summary-\(group.identifier)")
    }

    /// The figure's value and caption. A value the Journal read leaves nil is stated as unknown.
    private var figure: (String, String) {
        switch group {
        case .needsYou:
            let caption = pulse.needsYou.cards.isEmpty ? "nothing needs you" : "Cards need you"
            return ("\(pulse.needsYou.cards.count)", caption)
        case .now:
            if pulse.now.attempts.isEmpty {
                return (pulse.now.status.rawValue, pulse.now.nextActLine)
            }
            return ("\(pulse.now.attempts.count)", "Attempts running")
        case .feature:
            guard let feature = pulse.feature else { return ("—", "no Feature in flight") }
            let progress = feature.cardProgress
            let rollUp = feature.rollupState?.rawValue ?? "rollup state unknown"
            return ("\(progress.done)/\(progress.total)", "Cards · \(rollUp)")
        case .night:
            guard let night = pulse.night else { return ("—", "no Night yet") }
            return (night.state.rawValue, "started \(night.startedAt.formatted(date: .omitted, time: .shortened))")
        case .health:
            guard let health = pulse.health else { return ("—", "yh doctor not read") }
            return health.isEmpty ? ("OK", "no flags") : ("\(health.count)", "flags")
        }
    }
}

extension PulseGroup {
    /// The group's name in accessibility identifiers, e.g. `needs-you`.
    var identifier: String {
        switch self {
        case .needsYou: "needs-you"
        case .now: "now"
        case .feature: "feature"
        case .night: "night"
        case .health: "health"
        }
    }
}
