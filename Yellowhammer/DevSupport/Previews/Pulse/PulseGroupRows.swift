#if DEBUG
import Domain
import Pulse
import SwiftUI

// MARK: - Group rows

/// One group's rows. It returns several top-level views, so a `Form` or `List` gives each its own row
/// and a stack lays them out in order.
struct PulseGroupRows: View {
    let group: PulseGroup
    let context: PulseContext
    @Environment(\.pulsePalette) private var palette

    var body: some View {
        switch group {
        case .needsYou: needsYou
        case .now: now
        case .feature: feature
        case .night: night
        case .health: health
        }
    }

    private var actions: PulseActions { context.actions }

    @ViewBuilder
    private var needsYou: some View {
        let needsYou = context.pulse.needsYou
        if needsYou.cards.isEmpty {
            PulseAbsence(text: "Nothing needs you", systemImage: "checkmark.circle")
        } else {
            HStack(spacing: 6) {
                if needsYou.waitingOnYouCount > 0 {
                    PulseBadge(text: "\(needsYou.waitingOnYouCount) Waiting on You", color: palette.needsYou)
                }
                ForEach(needsYou.blockReasonCounts.prefix(3), id: \.reason) { entry in
                    PulseBadge(text: "\(entry.count) \(entry.reason.rawValue)", color: palette.blocked)
                }
            }
            ForEach(needsYou.cards) { card in
                Button { actions.inspect(.card(card.id)) } label: {
                    PulseCardRow(card: card)
                        .pulseRowHighlight(actions.inspected == .card(card.id), tint: palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var now: some View {
        let now = context.pulse.now
        LabeledContent("Status") {
            HStack(spacing: 6) {
                PulseStatusDot(color: palette.color(for: now.status))
                Text(now.status.rawValue)
            }
        }
        LabeledContent("Next Act") {
            if let next = now.nextAct {
                Text("\(next.act.rawValue) at \(PulseFormat.time(next.at))")
            } else {
                Text("none scheduled")
            }
        }
        if now.attempts.isEmpty {
            PulseAbsence(text: "No Attempt running", systemImage: "pause.circle")
        } else {
            ForEach(now.attempts) { attempt in
                Button { actions.inspect(.attempt(attempt.id)) } label: {
                    PulseAttemptRow(attempt: attempt, asOf: context.asOf)
                        .pulseRowHighlight(actions.inspected == .attempt(attempt.id), tint: palette.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var feature: some View {
        if let feature = context.pulse.feature {
            Button { actions.inspect(.feature(feature.id)) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.title ?? feature.id).fontWeight(.medium).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(feature.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let state = feature.state { PulseBadge(text: state) }
                        if let rollupState = feature.rollupState {
                            PulseBadge(text: rollupState.rawValue, color: palette.color(for: rollupState))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pulseRowHighlight(actions.inspected == .feature(feature.id), tint: palette.accent)
            }
            .buttonStyle(.plain)
            if feature.lanes.isEmpty {
                PulseAbsence(text: "No Repo Lane yet — the Feature is authoring", systemImage: "hourglass")
            } else {
                ForEach(feature.lanes) { lane in
                    PulseLaneRow(lane: lane, context: context)
                }
            }
        } else {
            PulseAbsence(text: "No Feature in flight", systemImage: "flag.slash")
        }
    }

    @ViewBuilder
    private var night: some View {
        if let night = context.pulse.night {
            Button { actions.open(.nightCard) } label: {
                HStack {
                    Text(night.verdictLine ?? "Night Card").multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open the Night Card in Linear")
            HStack(spacing: 8) {
                PulseBadge(text: night.state.rawValue, color: palette.color(for: night.state))
                Text("started \(PulseFormat.time(night.startedAt))").font(.caption).foregroundStyle(.secondary)
            }
            PulseDispositionCounts(night: night)
        } else {
            PulseAbsence(text: "No Night yet", systemImage: "moon.zzz")
        }
    }

    @ViewBuilder
    private var health: some View {
        if let health = context.pulse.health, !health.isEmpty {
            ForEach(health) { flag in
                Button { actions.open(.settings) } label: {
                    PulseHealthRow(flag: flag).contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } else if context.pulse.health == nil {
            PulseAbsence(text: "Not read — yh doctor was not run", systemImage: "questionmark.circle")
        } else {
            PulseAbsence(text: "Healthy — yh doctor raised nothing", systemImage: "checkmark.seal")
        }
    }
}
#endif
