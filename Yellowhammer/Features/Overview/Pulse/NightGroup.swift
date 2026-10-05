import Domain
import Pulse
import SwiftUI

/// The Pulse's Tonight / last Night group: `verdict_line`, `cards_by_disposition` counts, and the
/// Night's state (running / done / halted / starved). Opens the Night Card — the decision itself stays in
/// Linear.
///
/// The Journal read supplies a factual failure count; a full Night Summary remains unknown.
struct NightGroup: View {
    let night: NightPulse?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        PulseCard(group: .night, summary: PulseGroup.summary(of: night)) {
            if let night {
                if let link = night.nightCard {
                    Button { openDestination(.nightCard(link.url)) } label: {
                        HStack {
                            Text(night.displayVerdict).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(link.identifier) in Linear")
                    .accessibilityIdentifier("night-card-link")
                } else {
                    // No recorded link yet: the verdict is plain content, never a way out that goes nowhere.
                    HStack {
                        Text(night.displayVerdict).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                    }
                    .help("The Night Card's link is recorded when the engine next reads the board")
                    .accessibilityIdentifier("night-card-verdict")
                }
                HStack(spacing: 8) {
                    PulseCountBadge(text: night.state.rawValue, style: night.state.style)
                    Text("started \(night.startedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("night-state")
                if night.cardsByDisposition.isEmpty {
                    Text(night.cardsAbsence).foregroundStyle(.secondary)
                } else {
                    NightDispositionCounts(counts: night.cardsByDisposition)
                }
            } else {
                Label("No Night yet", systemImage: "moon.zzz")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("night-absence")
            }
        }
        .accessibilityIdentifier("pulse-night")
    }
}

/// Cards touched this Night, counted by disposition, in the order the read already ranks them.
private struct NightDispositionCounts: View {
    let counts: [DispositionCount]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(counts) { entry in
                Label {
                    Text(entry.displayCount).monospacedDigit()
                } icon: {
                    Circle().fill(entry.disposition.style).frame(width: 7, height: 7)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("night-dispositions")
    }
}

// MARK: For display

private extension NightPulse {
    /// `verdict_line`, or a stated unknown while it is nil (only Engine's `NightSummary` computes it).
    var displayVerdict: String { verdictLine ?? "verdict unknown" }
}

private extension DispositionCount {
    /// `6 Done`, its count and disposition.
    var displayCount: String { "\(count) \(disposition.rawValue)" }
}
