import Domain
import Pulse
import SwiftUI

/// The Pulse's Needs you group: the Waiting on You count, the top Block Reasons as counts, and every
/// decision Card, Blocked or Waiting on You. A Card opens in the Inspector in one hop, never through
/// the Night Card; the decision itself stays in Linear.
struct NeedsYouGroup: View {
    let needsYou: NeedsYou
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if needsYou.cards.isEmpty {
                    Label("Nothing needs you", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("needs-you-absence")
                } else {
                    NeedsYouCounts(
                        waitingOnYouCount: needsYou.waitingOnYouCount,
                        blockReasonCounts: needsYou.blockReasonCounts
                    )
                    ForEach(needsYou.cards) { card in
                        Button { openDestination(.inspector(.card(card.id))) } label: { DecisionCardRow(card: card) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("needs-you-card-\(card.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Needs you", systemImage: "hand.raised")
        }
        .accessibilityIdentifier("pulse-needs-you")
    }
}

/// The Waiting on You count and the top Block Reasons, as counts.
private struct NeedsYouCounts: View {
    let waitingOnYouCount: Int
    let blockReasonCounts: [(reason: BlockReason, count: Int)]

    /// How many Block Reasons the summary names before the Cards below it say the rest.
    private static let topReasons = 3

    var body: some View {
        HStack(spacing: 6) {
            if waitingOnYouCount > 0 {
                PulseCountBadge(text: "\(waitingOnYouCount) Waiting on You", tint: .orange)
            }
            ForEach(blockReasonCounts.prefix(Self.topReasons), id: \.reason) { entry in
                PulseCountBadge(text: "\(entry.count) \(entry.reason.rawValue)", tint: .red)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("needs-you-counts")
    }
}

/// One decision Card, Blocked or Waiting on You.
private struct DecisionCardRow: View {
    let card: DecisionCard

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: card.state == .blocked ? "exclamationmark.octagon.fill" : "questionmark.bubble.fill")
                .foregroundStyle(card.state == .blocked ? .red : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.title).lineLimit(1)
                Text("\(card.id) \u{00B7} \(card.repo)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(card.blockReason?.rawValue ?? card.state.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
    }
}
