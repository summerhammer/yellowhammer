import Domain
import Pulse
import SwiftUI

/// The Pulse's Tonight / last Night group: `verdict_line`, `cards_by_disposition` counts, and the
/// Night's state (running / done / starved). Opens the Night Card — the decision itself stays in
/// Linear.
///
/// `verdict_line` is nil from a Journal read: only Engine's `NightSummary` computes it. The group
/// states it as unknown rather than inventing one.
struct NightGroup: View {
    let night: NightPulse?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let night {
                    HStack(spacing: 6) {
                        PulseCountBadge(text: night.state.rawValue, style: night.state.style)
                        Text(night.displayVerdict)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("night-state")
                    if night.cardsByDisposition.isEmpty {
                        Text("No Cards touched").foregroundStyle(.secondary)
                    } else {
                        NightDispositionCounts(counts: night.cardsByDisposition)
                    }
                    Button("Night Card") { openDestination(.nightCard) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("night-card-link")
                } else {
                    Label("No Night yet", systemImage: "moon.stars")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("night-absence")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Tonight / last Night", systemImage: "moon.stars")
        }
        .accessibilityIdentifier("pulse-night")
    }
}

/// Cards touched this Night, counted by disposition, in the order the read already ranks them.
private struct NightDispositionCounts: View {
    let counts: [DispositionCount]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(counts) { entry in
                Text(entry.displayCount)
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
